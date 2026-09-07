defmodule Cairn.Camera do
  @moduledoc """
  Per-camera supervision tree, `:one_for_one` over two subtrees: `:media`
  (`Cairn.Camera.Media`, the media chain) ahead of `:lane`
  (`Cairn.Camera.Lane`, the event workers).

  `:one_for_one` because the two are independent: the media reaches the lane
  by resolving Registry names per batch and casting, so a lane worker
  restarting is invisible to it — and `:rest_for_one` here would bounce the
  RTSP connection every time a lane worker crash-looped past its intensity.

  What the order decides is the **stop**, which runs in reverse: the lane goes
  first, while its media is still standing. That is what the lane's
  `terminate/2` needs — `Cairn.CameraTracker` and `Cairn.PresenceRecorder`
  each cast a finalize to an extractor that is still draining a live
  `Cairn.RingBuffer`, and the tracker labels the tracks it ends
  `:camera_stopped`, which is what actually happened to them. Stopping the
  media first inverts that: `Cairn.PipelineOwner.terminate/2` publishes the
  camera's `:camera_stopped` epoch, and the tracker's `apply_epoch/3` — a
  message, so it is handled long before the supervisor gets round to stopping
  the lane — has already ended every live track `:stream_reset` and counted a
  stream reset that never happened.

  The cost is at the start, and it is nothing: the pipeline can produce a
  batch or two before the lane holds its Registry names, and those are cast to
  absent names and dropped with a debug line
  (`Cairn.CameraTracker.tracked/3`). A camera that has been up for a second
  has lost at most its first few frames of detections, where the old order
  risked mislabelling every track the camera ever held.

  A restart-class config change replaces `:media` alone
  (`Cairn.CameraSupervisor.restart_media/2`) — the restart-class fields are
  baked into that subtree's arguments, so it is rebuilt from the new camera
  rather than restarted from the old — and this supervisor, its name and the
  lane survive it. A camera added or removed is this whole tree started or
  stopped.

  Escalation is three-level: `Cairn.Camera.Media`'s intensity, then this
  supervisor's (which restarts `:media` alone, `:one_for_one`), then
  `Cairn.CameraSupervisor`'s, which rebuilds the whole tree. The `:camera`
  Registry name survives the first two, so a camera whose media is
  crash-looping still counts as running to `Cairn.CameraSupervisor.sync/1`.

  `init/1` builds both subtrees from the config server's published snapshot
  when it names this camera, and from the opts pair only when it does not (no
  snapshot yet, or a test's fixture camera). That is what makes the third
  level safe: `Cairn.CameraSupervisor` restarts this tree from the spec it
  was started with, which a media replacement cannot rewrite, so a rebuild
  reading only those args would revert the camera to its pre-change
  restart-class fields and stay there.
  """

  use Supervisor

  alias Cairn.Config

  def start_link(opts) do
    cam = Keyword.fetch!(opts, :camera)
    Supervisor.start_link(__MODULE__, opts, name: Cairn.Registry.via(cam.id, :camera))
  end

  @impl true
  def init(opts) do
    opts = resolve(opts)
    Supervisor.init([media_spec(opts), lane_spec(opts)], strategy: :one_for_one)
  end

  # One resolved pair for the whole tree: the ring's pre-window, the bridge's
  # argv and the owner's restart-class fields have to describe the same camera
  # (`Cairn.PipelineOwner.latest/3` keeps those fields from its opts precisely
  # because its siblings were built from them). The lookup is threaded into
  # `owner_opts` so the owner's own snapshot read is the identical function —
  # a test seam given here or in `owner_opts` reaches both levels.
  defp resolve(opts) do
    lookup = config_lookup(opts)
    cam = Keyword.fetch!(opts, :camera)

    {cam, config} =
      case lookup.(cam.id) do
        {:ok, snap_cam, snap_config} -> {snap_cam, snap_config}
        :error -> {cam, Keyword.fetch!(opts, :config)}
      end

    opts
    |> Keyword.merge(camera: cam, config: config, config_lookup: lookup)
    |> Keyword.update(
      :owner_opts,
      [config_lookup: lookup],
      &Keyword.put_new(&1, :config_lookup, lookup)
    )
  end

  defp config_lookup(opts) do
    Keyword.get_lazy(opts, :config_lookup, fn ->
      opts
      |> Keyword.get(:owner_opts, [])
      |> Keyword.get(:config_lookup, &Config.Server.snapshot_camera/1)
    end)
  end

  @doc false
  @spec media_spec(keyword()) :: Supervisor.child_spec()
  def media_spec(opts), do: Supervisor.child_spec({Cairn.Camera.Media, opts}, id: :media)

  defp lane_spec(opts), do: Supervisor.child_spec({Cairn.Camera.Lane, opts}, id: :lane)
end
