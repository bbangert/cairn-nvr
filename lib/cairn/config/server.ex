defmodule Cairn.Config.Server do
  @moduledoc """
  Holds the active `Cairn.Config`. Loads YAML at boot; `reload/0` re-reads,
  validates, diffs cameras against the running set and applies the diff
  (start/stop/restart camera trees, and refresh in place the cameras whose
  change reaches no subprocess). An invalid reload keeps the old config and
  returns the errors.

  Detection lives in `Cairn.Native.Host`, so the new config goes there
  first (`reconfigure/1`) — the model a camera's next session opens a
  stream on should already be the new one when its tree restarts.
  """

  use GenServer

  require Logger

  alias Cairn.Config
  alias Cairn.Native.Host

  @type diff :: %{
          added: [String.t()],
          removed: [String.t()],
          changed: [String.t()],
          refreshed: [String.t()]
        }

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec get(GenServer.server()) :: Config.t()
  def get(server \\ __MODULE__), do: GenServer.call(server, :get)

  @spec camera(String.t()) :: {:ok, Config.Camera.t()} | :error
  def camera(camera_id, server \\ __MODULE__) do
    case Enum.find(get(server).cameras, &(&1.id == camera_id)) do
      nil -> :error
      cam -> {:ok, cam}
    end
  end

  @spec data_dir(GenServer.server()) :: String.t()
  def data_dir(server \\ __MODULE__), do: get(server).data_dir

  @doc "Configured HA integration token, or `nil` when the integration is disabled."
  @spec ha_token(GenServer.server()) :: String.t() | nil
  def ha_token(server \\ __MODULE__), do: get(server).ha_token

  @doc "Warnings and errors from the last load/reload attempt (for the UI)."
  @spec last_load(GenServer.server()) :: %{warnings: [String.t()], errors: [String.t()]}
  def last_load(server \\ __MODULE__), do: GenServer.call(server, :last_load)

  @spec reload(GenServer.server()) ::
          {:ok, diff(), [String.t()]} | {:error, [String.t()]}
  def reload(server \\ __MODULE__), do: GenServer.call(server, :reload, 30_000)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path) || Config.default_path()
    apply_diff = Keyword.get(opts, :apply_diff, &Cairn.CameraSupervisor.apply_diff/2)
    apply_native = Keyword.get(opts, :apply_native, &Host.reconfigure/1)

    state = %{
      path: path,
      apply_diff: apply_diff,
      apply_native: apply_native,
      config: %Config{},
      warnings: [],
      errors: []
    }

    case Config.load(path) do
      {:ok, config, warnings} ->
        Enum.each(warnings, &Logger.warning("config: #{&1}"))
        Cairn.DataDir.ensure!(config.data_dir)
        {:ok, %{state | config: config, warnings: warnings}}

      {:error, errors} ->
        Enum.each(errors, &Logger.error("config: #{&1}"))
        Logger.error("config: starting with empty defaults (no cameras)")
        Cairn.DataDir.ensure!(state.config.data_dir)
        {:ok, %{state | errors: errors}}
    end
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.config, state}

  def handle_call(:last_load, _from, state) do
    {:reply, %{warnings: state.warnings, errors: state.errors}, state}
  end

  def handle_call(:reload, _from, state) do
    case Config.load(state.path) do
      {:ok, new_config, warnings} ->
        diff = diff_cameras(state.config, new_config)
        # Before the diff: newly spawned ports redirect logs into the (possibly
        # changed) data_dir, so its log subdir must already exist
        Cairn.DataDir.ensure!(new_config.data_dir)
        # Before the cameras: detection is the in-VM engine, so the model a
        # restarted camera will open a stream on should already be the new
        # one. The call is asynchronous, so this is an ordering of sends
        # rather than of loads.
        state.apply_native.(new_config)
        state.apply_diff.(diff, new_config)
        state = %{state | config: new_config, warnings: warnings, errors: []}
        {:reply, {:ok, diff, warnings}, state}

      {:error, errors} ->
        {:reply, {:error, errors}, %{state | errors: errors}}
    end
  end

  @doc false
  @spec diff_cameras(Config.t(), Config.t()) :: diff()
  def diff_cameras(old, new) do
    old_by_id = Map.new(old.cameras, &{&1.id, &1})
    new_by_id = Map.new(new.cameras, &{&1.id, &1})
    old_ids = MapSet.new(Map.keys(old_by_id))
    new_ids = MapSet.new(Map.keys(new_by_id))

    # `changed` restarts the camera's tree, `refreshed` hands the running one
    # the new config: a camera is in exactly one of them, and in neither when
    # nothing about it moved.
    {changed, refreshed} =
      Enum.reduce(MapSet.intersection(old_ids, new_ids), {[], []}, fn id, {changed, refreshed} ->
        cond do
          camera_changed?(old, new, old_by_id[id], new_by_id[id]) -> {[id | changed], refreshed}
          camera_refreshed?(old, new, old_by_id[id], new_by_id[id]) -> {changed, [id | refreshed]}
          true -> {changed, refreshed}
        end
      end)

    diff(old_ids, new_ids, changed, refreshed)
  end

  # The camera inputs that reach a subprocess or are baked into a child spec
  # at tree init, and so cannot be swapped into a running camera:
  # `rtsp_url`, `transcode` and `extra_ffmpeg_args` are ffmpeg's argv;
  # `plugin` selects the profile the detect branch is built on and
  # `min_score` the stream params it opens with — both resolved at session
  # start, not refreshable into an open stream.
  #
  # The contract for a field added to `Cairn.Config.Camera` later: the
  # default is refresh-only. Nothing lands in this list by being new — it
  # goes here only on the deliberate finding that it reaches a subprocess.
  # `ingest` is here because it selects the session's source process itself
  # (the ffmpeg OS process vs the RTSP client) and the pipeline's ingest
  # chain — nothing a running session can swap in place.
  @restart_fields [
    :rtsp_url,
    :plugin,
    :ingest,
    :min_score,
    :transcode,
    :extra_ffmpeg_args
  ]

  # `pre_window_seconds` is compared *resolved* rather than read off the
  # camera struct (camera override or global): `Cairn.Camera.init/1` bakes
  # it into the RingBuffer child spec, so a pre-window refreshed in place
  # would leave the ring at its old capacity while everything else believed
  # the new one.
  #
  # The rest of the effective policy — `post`/`max`, the tracking bounds, the
  # `track:` / `record:` tiers — is host-side and refreshes in place through
  # `Cairn.PipelineOwner.refresh/3`.
  defp camera_changed?(old, new, old_cam, new_cam) do
    Map.take(old_cam, @restart_fields) != Map.take(new_cam, @restart_fields) or
      Config.windows(old, old_cam).pre != Config.windows(new, new_cam).pre
  end

  # Everything else the running camera was handed: the camera struct itself
  # (the tiers, retention, the refresh-only windows) and its effective
  # policy, which a *global* window or tracking edit moves without touching
  # the struct.
  defp camera_refreshed?(old, new, old_cam, new_cam) do
    old_cam != new_cam or Config.policy(old, old_cam) != Config.policy(new, new_cam)
  end

  defp diff(old_keys, new_keys, changed, refreshed) do
    %{
      added: MapSet.difference(new_keys, old_keys) |> Enum.sort(),
      removed: MapSet.difference(old_keys, new_keys) |> Enum.sort(),
      changed: Enum.sort(changed),
      refreshed: Enum.sort(refreshed)
    }
  end
end
