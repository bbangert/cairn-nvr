defmodule Cairn.Config.Server do
  @moduledoc """
  Holds the active `Cairn.Config`. Loads YAML at boot; `reload/0` re-reads,
  validates, diffs plugin groups and cameras against the running set and
  applies both diffs (start/stop/restart group and camera children, and
  refresh in place the cameras whose change reaches no subprocess). An
  invalid reload keeps the old config and returns the errors.

  Group children are applied before camera children: a group bakes its
  members' UDP ports into its argv, so it should be listening before the
  ffmpeg outputs feeding it come back.
  """

  use GenServer

  require Logger

  alias Cairn.Config

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
    apply_group_diff = Keyword.get(opts, :apply_group_diff, &default_apply_group_diff/2)

    state = %{
      path: path,
      apply_diff: apply_diff,
      apply_group_diff: apply_group_diff,
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
        group_diff = diff_plugin_groups(state.config, new_config)
        diff = diff_cameras(state.config, new_config)
        # Before the diffs: newly spawned ports redirect logs into the (possibly
        # changed) data_dir, so its log subdir must already exist
        Cairn.DataDir.ensure!(new_config.data_dir)
        log_group_diff(group_diff)
        state.apply_group_diff.(group_diff, new_config)
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
    old_index = index_by_id(old.cameras)
    new_index = index_by_id(new.cameras)
    old_ids = MapSet.new(Map.keys(old_by_id))
    new_ids = MapSet.new(Map.keys(new_by_id))

    # `changed` restarts the camera's tree, `refreshed` hands the running one
    # the new config: a camera is in exactly one of them, and in neither when
    # nothing about it moved.
    {changed, refreshed} =
      Enum.reduce(MapSet.intersection(old_ids, new_ids), {[], []}, fn id, {changed, refreshed} ->
        old_side = {old_by_id[id], old_index[id]}
        new_side = {new_by_id[id], new_index[id]}

        cond do
          camera_changed?(old, new, old_side, new_side) -> {[id | changed], refreshed}
          camera_refreshed?(old, new, old_side, new_side) -> {changed, [id | refreshed]}
          true -> {changed, refreshed}
        end
      end)

    diff(old_ids, new_ids, changed, refreshed)
  end

  # Compared whole, where a camera is compared field by field
  # (`@restart_fields`). `command` carries the model flags `Cairn.Config`
  # expands from a `profile:`, and the resolved `Cairn.Config.Profile` struct
  # rides along beside it — so editing the profile *file* under an unchanged
  # name moves this comparison exactly as pointing the group at a different
  # profile does, which is what gets new model argv to the plugin.
  #
  # Whole-struct is deliberately wider than the argv: a profile edit that
  # touches only its `tracking:` block restarts the group too, though the
  # stages are host-side and reach a running camera through the policy
  # refresh (`camera_refreshed?/4`) on their own. Over-restarting is the safe
  # direction — the cost is one model reload and the group's live tracks —
  # and narrowing it means classifying a *profile's* fields by consumption
  # site, not a group's.
  @doc false
  @spec diff_plugin_groups(Config.t(), Config.t()) :: diff()
  def diff_plugin_groups(old, new) do
    old_by_name = Map.new(old.plugin_groups, &{&1.name, &1})
    new_by_name = Map.new(new.plugin_groups, &{&1.name, &1})
    old_names = MapSet.new(Map.keys(old_by_name))
    new_names = MapSet.new(Map.keys(new_by_name))

    changed =
      for name <- MapSet.intersection(old_names, new_names),
          old_by_name[name] != new_by_name[name],
          do: name

    # Groups never classify as `refreshed`: `Cairn.PluginGroupSupervisor`
    # refreshes every surviving group on every sync, whether or not anything
    # about it moved, so there is nothing for this diff to single out.
    diff(old_names, new_names, changed, [])
  end

  # The camera inputs that reach a subprocess or are baked into a child spec
  # at tree init, and so cannot be swapped into a running camera:
  # `rtsp_url`, `transcode` and `extra_ffmpeg_args` are ffmpeg's argv;
  # `plugin` and `min_score` are the plugin's (`--min-score-json` inline, the
  # member entry in a group's `--cameras-json`).
  #
  # `min_score` is here for the *inline* camera. For a `{:group, _}` one the
  # tree restart delivers nothing — the group's argv is rebuilt from
  # `Cairn.Config`'s `members_for/2` and reaches the plugin through
  # `diff_plugin_groups/2`'s whole-struct comparison instead — but the bounce
  # is harmless, and dropping the field for group members would silently stop
  # inline cameras from ever seeing a new wire floor.
  #
  # The contract for a field added to `Cairn.Config.Camera` later: the
  # default is refresh-only. Nothing lands in this list by being new — it
  # goes here only on the deliberate finding that it reaches a subprocess.
  @restart_fields [:rtsp_url, :plugin, :pipeline, :min_score, :transcode, :extra_ffmpeg_args]

  # Two things are compared *resolved* rather than read off the camera
  # struct, because both are baked at tree init out of config the struct does
  # not carry:
  #
  #   * the UDP ports. They are positional (`Cairn.UDPPorts`), so moving in
  #     the `cameras:` list shifts them — and so does a global
  #     `udp.base_port` edit, which moves every camera's ports while leaving
  #     every camera struct and every index untouched. The index is what the
  #     tree is handed; the ports are what it means, and only comparing the
  #     ports catches the global edit.
  #   * `pre_window_seconds` (camera override or global). `Cairn.Camera.init/1`
  #     bakes it into the RingBuffer child spec, so a pre-window refreshed in
  #     place would leave the ring at its old capacity while everything else
  #     believed the new one.
  #
  # The rest of the effective policy — `post`/`max`, the tracking bounds, the
  # `track:` / `record:` tiers — is host-side and refreshes
  # (`Cairn.PluginPort.refresh/3`).
  defp camera_changed?(old, new, {old_cam, old_index}, {new_cam, new_index}) do
    old_index != new_index or
      udp_ports(old, old_index) != udp_ports(new, new_index) or
      Map.take(old_cam, @restart_fields) != Map.take(new_cam, @restart_fields) or
      Config.windows(old, old_cam).pre != Config.windows(new, new_cam).pre
  end

  # A validated config always carries an integer `udp_base_port` (`Cairn.Config`
  # rejects a missing one), but this compares two arbitrary configs: an
  # unvalidated one answers `nil` here rather than raising out of a reload.
  defp udp_ports(%Config{udp_base_port: base} = config, index) when is_integer(base),
    do: Cairn.UDPPorts.ports_for(config, index)

  defp udp_ports(_config, _index), do: nil

  # Everything else the running camera was handed: the camera struct itself
  # (the tiers, retention, the refresh-only windows) and its effective
  # policy, which a *global* window or tracking edit moves without touching
  # the struct.
  defp camera_refreshed?(old, new, {old_cam, _old_index}, {new_cam, _new_index}) do
    old_cam != new_cam or Config.policy(old, old_cam) != Config.policy(new, new_cam)
  end

  defp index_by_id(cameras) do
    cameras |> Enum.with_index() |> Map.new(fn {cam, index} -> {cam.id, index} end)
  end

  defp diff(old_keys, new_keys, changed, refreshed) do
    %{
      added: MapSet.difference(new_keys, old_keys) |> Enum.sort(),
      removed: MapSet.difference(old_keys, new_keys) |> Enum.sort(),
      changed: Enum.sort(changed),
      refreshed: Enum.sort(refreshed)
    }
  end

  defp log_group_diff(%{added: [], removed: [], changed: []}), do: :ok

  defp log_group_diff(group_diff) do
    Logger.info(
      "config: plugin groups added=#{inspect(group_diff.added)} " <>
        "removed=#{inspect(group_diff.removed)} changed=#{inspect(group_diff.changed)}"
    )
  end

  defp default_apply_group_diff(group_diff, config) do
    Cairn.PluginGroupSupervisor.apply_diff(group_diff, config)
  end
end
