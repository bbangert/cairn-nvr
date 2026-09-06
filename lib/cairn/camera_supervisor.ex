defmodule Cairn.CameraSupervisor do
  @moduledoc """
  DynamicSupervisor over per-camera supervision trees (`Cairn.Camera`).

  `sync/1` reconciles running cameras against a config; `apply_diff/2`
  applies a reload diff, replacing the media subtree of the cameras it marks
  `changed` (`restart_media/2`) and handing the new config to the ones it
  marks `refreshed` (`refresh_camera/2`).
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

  A `refreshed` camera is one deliberately left running: its running session
  still holds the pre-reload policy, so it is handed the new one instead of
  being restarted. A `changed` camera keeps its tree and gets a new `:media`
  subtree; only a `removed` one is stopped.
  """
  @spec apply_diff(Config.Server.camera_diff(), Config.t()) :: :ok
  # The four camera keys are matched in the head: they are the contract
  # (`Cairn.Config.Server.camera_diff/0`, which the broadcast diff carries
  # alongside keys this never reads), and a caller handing a partial
  # map should fail here, loudly, not by KeyError three lines in — and not be
  # silently tolerated with defaults, which would let a malformed diff skip
  # work it named.
  def apply_diff(
        %{removed: removed, changed: changed, refreshed: refreshed, added: _},
        %Config{} = new_config
      ) do
    Enum.each(removed, &stop_camera/1)
    Enum.each(changed, &restart_media(new_config, &1))
    sync(new_config)
    Enum.each(refreshed, &refresh_camera(new_config, &1))
  end

  @doc """
  Replaces a running camera's `:media` subtree with one built from the new
  camera and config, leaving the camera's supervisor, name and `:lane` in
  place. Terminate, delete and start rather than `restart_child/2`: the
  restart-class fields live in the subtree's child arguments, and a restart
  would rebuild it from the struct the tree was born with. A camera that is
  not running has nothing to replace — `sync/1` starts it.

  The presence aggregator is retired in the gap between the old media dying
  and the new one starting, exactly where `stop_camera/1` retires it: with the
  producer dead nothing can recreate an aggregator mid-await, so the new
  pipeline finds the registration gone rather than a dying pid that would
  swallow its first observations. It moves into the lane later
  (`design-supervision.md`, S2); until then this keeps a `changed` camera's
  presence from outliving the config that meant tier 1.

  A start that fails is logged, not raised: `apply_diff/2` walks every changed
  camera and one bad config must not strand the rest. That camera's tree is
  then stopped, so it is absent rather than registered-but-dark: `do_sync`
  skips a registered camera, and a camera left with no `:media` would never be
  retried by any later reload. Stopped, the `sync/1` below in `apply_diff/2`
  and every reload after it start it again through `start_camera/2`.
  """
  @spec restart_media(Config.t(), String.t()) :: :ok
  def restart_media(%Config{} = config, camera_id) do
    with %Config.Camera{} = cam <- Enum.find(config.cameras, &(&1.id == camera_id)),
         pid when is_pid(pid) <- Cairn.Registry.whereis(camera_id, :camera) do
      # After a terminate that found the child, the delete cannot fail —
      # asserted rather than ignored. `:not_found` is unreachable while every
      # registered camera has a `:media` (a failed start below stops the whole
      # tree); it is tolerated rather than matched away so a path that ever
      # loses that child starts a new one here instead of raising.
      case Supervisor.terminate_child(pid, :media) do
        :ok -> :ok = Supervisor.delete_child(pid, :media)
        {:error, :not_found} -> :ok
      end

      Cairn.PresenceAggregator.retire(camera_id)
      Cairn.Registry.await_unregistered(camera_id, :presence)

      # The old chain's Registry names are deliberately not awaited here, and
      # the start below is not racing them: `Registry.register/3` deletes a
      # unique entry whose owner is dead and retries, so a name the registry
      # has not yet reaped on the dead owner's DOWN is taken, not refused.
      # Only a *live* holder yields `{:already_registered, _}` — a stale entry
      # is visible to `Cairn.Registry.whereis/2`, which does not filter dead
      # pids, but that is a reader's problem (`sync/1`), not a registrant's.
      case Supervisor.start_child(pid, Cairn.Camera.media_spec(camera: cam, config: config)) do
        {:ok, _media} ->
          :ok

        other ->
          Logger.error("camera #{camera_id}: failed to start new media: #{inspect(other)}")
          stop_camera(camera_id)
      end
    else
      _absent -> :ok
    end
  end

  @doc """
  Hands a still-running camera's pipeline owner the new camera and config — it
  owns the pipeline whose sink applies the policy. A camera that is not
  running has no process to tell, and the config lookup guards the case a
  diff cannot produce: an id `config` does not carry.

  A bridge camera's `Cairn.FFmpegPort` is deliberately not told: every field
  its argv reads (`rtsp_url`, `transcode`, `extra_ffmpeg_args`) is a
  `Cairn.Config.Server` restart field, so a camera whose argv moved is
  `changed` and has its media subtree replaced rather than refreshed.
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
    case Cairn.Registry.whereis(camera_id, :camera) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        Cairn.Registry.await_unregistered(camera_id, :camera)
    end

    # The camera's presence aggregator goes with it — this function runs for
    # removed cameras and for a changed one whose new media would not start
    # (`restart_media/2` retires it itself for the ordinary replacement),
    # never for a crash/watchdog rebuild, which is exactly the split presence
    # wants: survive reconnects, but never outlive the config that meant tier 1
    # (`Cairn.PresenceAggregator.retire/1` clears before stopping). AFTER
    # the camera tree above, and awaited: with the producer dead nothing can
    # recreate an aggregator mid-await, and a replacement camera started
    # once this returns finds the registration gone rather than a dying pid
    # that would swallow its first observations.
    Cairn.PresenceAggregator.retire(camera_id)
    Cairn.Registry.await_unregistered(camera_id, :presence)
  end
end
