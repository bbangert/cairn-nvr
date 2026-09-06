defmodule Cairn.Camera do
  @moduledoc """
  Per-camera supervision tree, `:one_for_one` over two subtrees: `:lane`
  (`Cairn.Camera.Lane`, the event workers) ahead of `:media`
  (`Cairn.Camera.Media`, the media chain).

  `:one_for_one` because the two are independent: the media reaches the lane
  by resolving Registry names per batch and casting, so a lane worker
  restarting is invisible to it — and `:rest_for_one` here would bounce the
  RTSP connection every time a lane worker crash-looped past its intensity.
  Order still does its two jobs — the lane's names exist before the first
  batch arrives, and shutdown runs in reverse: media first, so the source is
  quiet before the workers that finalize its events stop.

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
    Supervisor.init([lane_spec(opts), media_spec(opts)], strategy: :one_for_one)
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
