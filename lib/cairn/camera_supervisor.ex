defmodule Cairn.CameraSupervisor do
  @moduledoc """
  DynamicSupervisor over per-camera supervision trees (`Cairn.Camera`).

  `sync/1` reconciles running cameras against a config; `apply_diff/2`
  applies a reload diff, replacing the media subtree of the cameras it marks
  `changed` (`restart_media/2`), stopping and restarting the whole tree of the
  ones it marks `rebuilt`, and handing the new config to the ones it marks
  `refreshed` (`refresh_camera/2`).
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
  subtree. A `rebuilt` one is stopped like a `removed` one and started again by
  the `sync/1` below, because what moved is the composition of its `:lane`
  (`Cairn.Camera.Lane` — which event workers a tier means), and a running
  supervisor cannot be edited into a different child list.
  """
  @spec apply_diff(Config.Server.camera_diff(), Config.t()) :: :ok
  # The five camera keys are matched in the head: they are the contract
  # (`Cairn.Config.Server.camera_diff/0`, which the broadcast diff carries
  # alongside keys this never reads), and a caller handing a partial
  # map should fail here, loudly, not by KeyError three lines in — and not be
  # silently tolerated with defaults, which would let a malformed diff skip
  # work it named.
  def apply_diff(
        %{removed: removed, changed: changed, rebuilt: rebuilt, refreshed: refreshed, added: _},
        %Config{} = new_config
      ) do
    Enum.each(removed, &stop_camera/1)
    # Before `sync/1`, which is what starts them again — from the new config,
    # so the new tree's lane is built for the new tier. That makes `rebuilt`
    # the one class whose restart rides `sync/1`, and therefore the one the
    # `:start_cameras` flag can suppress: with it false a rebuilt camera stops
    # and stays stopped, where a changed one is replaced regardless. Only the
    # test env sets it (`config/test.exs`), where no camera should be running
    # to begin with.
    Enum.each(rebuilt, &stop_camera/1)
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

  The `:lane` workers run on through the gap, which is the point of the split:
  a restart-class change leaves the camera's tier alone (a tier flip is
  `rebuilt`, not `changed`), so its presence state survives a new pipeline.
  An open CLIP does not, and cannot: the ring is inside `:media`, and the
  extractor's subscription is held by the ring it drained, which no
  replacement inherits. The extractor monitors that ring and closes the clip
  `:finalized` when it goes, and the recorder — still holding the present keys
  — opens the next clip on the new ring. A reconnect is the case that differs:
  the ring is ahead of the pipeline in `Cairn.Camera.Media`, so it survives one
  and the clip runs on unbroken.

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
  Hands a still-running camera the new camera and config: its pipeline owner,
  which owns the pipeline whose sink applies the policy, and then each `:lane`
  worker, which is how a refresh-class field reaches a worker the tree built
  from the pre-change pair. A camera that is not running has no process to
  tell, and the config lookup guards the case a diff cannot produce: an id
  `config` does not carry.

  The lane casts are dropped when the name is absent — a tier-2 camera has no
  presence workers, and a tier-1 one may have a worker mid-restart, which
  resolves the config for itself in `init/1` anyway.

  A bridge camera's `Cairn.FFmpegPort` is deliberately not told: every field
  its argv reads (`rtsp_url`, `transcode`, `extra_ffmpeg_args`) is a
  `Cairn.Config.Server` restart field, so a camera whose argv moved is
  `changed` and has its media subtree replaced rather than refreshed.
  """
  @spec refresh_camera(Config.t(), String.t()) :: :ok
  def refresh_camera(%Config{} = config, camera_id) do
    case Enum.find(config.cameras, &(&1.id == camera_id)) do
      %Config.Camera{} = cam -> refresh_tree(config, cam)
      nil -> :ok
    end
  end

  defp refresh_tree(config, cam) do
    case Cairn.Registry.whereis(cam.id, :pipeline) do
      pid when is_pid(pid) -> Cairn.PipelineOwner.refresh(pid, cam, config)
      nil -> :ok
    end

    Cairn.PresenceAggregator.refresh(cam.id, cam, config)
    Cairn.PresenceRecorder.refresh(cam.id, cam, config)
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
  end
end
