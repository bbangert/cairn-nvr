defmodule Cairn.CameraSupervisor do
  @moduledoc """
  DynamicSupervisor over per-camera supervision trees (`Cairn.Camera`).

  `sync/1` reconciles running cameras against a config; `apply_diff/2`
  applies a reload diff, restarting the cameras it marks `changed` and
  handing the new config to the ones it marks `refreshed`
  (`refresh_camera/2`).
  """

  use DynamicSupervisor

  require Logger

  alias Cairn.Config

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Starts all cameras from `config` that are not already running."
  @spec sync(Config.t()) :: :ok
  def sync(%Config{} = config) do
    if Application.get_env(:cairn, :start_cameras, true) do
      do_sync(config)
    else
      :ok
    end
  end

  defp do_sync(config) do
    running = MapSet.new(Cairn.Registry.ids_for_role(:camera))
    wanted = MapSet.new(config.cameras, & &1.id)

    Enum.each(MapSet.difference(running, wanted), &stop_camera/1)

    Enum.each(config.cameras, fn cam ->
      unless MapSet.member?(running, cam.id), do: start_camera(config, cam)
    end)
  end

  @doc """
  Applies a `Cairn.Config.Server` reload diff against `new_config`.

  A `refreshed` camera is one the stop+sync above deliberately left running:
  its running session still holds the pre-reload policy, so it is handed
  the new one instead of being restarted.
  """
  @spec apply_diff(Config.Server.diff(), Config.t()) :: :ok
  # The full diff shape is matched in the head: all four keys are the
  # contract (`Cairn.Config.Server.diff/0`), and a caller handing a partial
  # map should fail here, loudly, not by KeyError three lines in — and not be
  # silently tolerated with defaults, which would let a malformed diff skip
  # work it named.
  def apply_diff(
        %{removed: removed, changed: changed, refreshed: refreshed, added: _},
        %Config{} = new_config
      ) do
    Enum.each(removed ++ changed, &stop_camera/1)
    sync(new_config)
    Enum.each(refreshed, &refresh_camera(new_config, &1))
  end

  @doc """
  Hands a still-running camera's pipeline owner the new camera and config — it
  owns the pipeline whose sink applies the policy. A camera that is not
  running has no process to tell, and the config lookup guards the case a
  diff cannot produce: an id `config` does not carry.

  A bridge camera's `Cairn.FFmpegPort` is deliberately not told: every field
  its argv reads (`rtsp_url`, `transcode`, `extra_ffmpeg_args`) is a
  `Cairn.Config.Server` restart field, so a camera whose argv moved is
  `changed` and restarted whole rather than refreshed.
  """
  @spec refresh_camera(Config.t(), String.t()) :: :ok
  def refresh_camera(%Config{} = config, camera_id) do
    with %Config.Camera{} = cam <- Enum.find(config.cameras, &(&1.id == camera_id)),
         pid when is_pid(pid) <- Cairn.Registry.whereis(camera_id, :pipeline) do
      Cairn.PipelineOwner.refresh(pid, cam, config)
    else
      _absent -> :ok
    end
  end

  @spec start_camera(Config.t(), Config.Camera.t()) :: DynamicSupervisor.on_start_child()
  def start_camera(%Config{} = config, cam) do
    spec = {Cairn.Camera, camera: cam, config: config}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("camera #{cam.id}: failed to start: #{inspect(reason)}")
        error
    end
  end

  @spec stop_camera(String.t()) :: :ok
  def stop_camera(camera_id) do
    # The camera's presence aggregator goes with it — this function runs for
    # removed and changed (restarting) cameras, never for a crash/watchdog
    # rebuild, which is exactly the split presence wants: survive
    # reconnects, but never outlive the config that meant tier 1
    # (`Cairn.PresenceAggregator.retire/1` clears before stopping).
    Cairn.PresenceAggregator.retire(camera_id)

    case Cairn.Registry.whereis(camera_id, :camera) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        Cairn.Registry.await_unregistered(camera_id, :camera)
    end
  end
end
