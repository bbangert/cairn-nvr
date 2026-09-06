defmodule Cairn.Camera.Media do
  @moduledoc """
  A camera's media chain, `:rest_for_one`: `RingBuffer` -> (`FFmpegPort`,
  bridge cameras only) -> `PipelineOwner` -> `RTPHub`, plus a `:temporary`
  probe task ahead of them, outside the restart chain this order describes.
  Ring death restarts the ingest (a fresh ring is empty anyway); ingest death
  restarts only its downstream consumers.

  `FFmpegPort` sits above the owner because the pipeline consumes its bytes:
  the restart chain follows the media, so a port that died mid-session — never
  having cut it in band — takes the pipeline holding that half-session with it.
  A camera on `ingest: rtsp` has no port at all: its sessions live inside
  `Membrane.RTSPDualStream.Source`.

  This is the `:media` child of `Cairn.Camera`. A restart-class config change
  replaces this subtree alone (`Cairn.CameraSupervisor.restart_media/2`): the
  restart-class fields are baked into these children's arguments, so a
  replacement is built from the new camera rather than restarted from the old
  one — and the rest of the camera tree survives it: only this child is
  terminated, and its parent is `:one_for_one`.

  Detection is not in this tree: the camera's pipeline feeds the node's one
  in-VM engine (`Cairn.Native.Host`) at the end of its detect branch, and its
  hub is fed by that pipeline's RTP branch. The pipeline is long-lived and
  rebuilt only by `Cairn.PipelineOwner`, so neither branch is rebuilt by a
  reconnect and a supervisor restart cannot decouple the two.
  """

  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    cam = Keyword.fetch!(opts, :camera)
    config = Keyword.fetch!(opts, :config)
    windows = Cairn.Config.windows(config, cam)

    children =
      [
        %{
          id: :probe,
          start: {Task, :start_link, [Cairn.Probe, :run_and_store, [cam]]},
          restart: :temporary
        },
        {Cairn.RingBuffer, camera_id: cam.id, pre_window_seconds: windows.pre}
      ] ++
        bridge(cam, config) ++
        [
          # `owner_opts` is the tests' seam into the owner (a stub pipeline, a
          # config lookup). A whole-tree start threads the tree's resolved
          # `config_lookup` in here; a media replacement from
          # `restart_media/2` passes no `owner_opts` at all, so the owner
          # falls back to the application snapshot — identical in production,
          # but a test that injected a tree-level lookup does not keep it
          # across a media replacement (the same footgun the next clause
          # warns about, by another door). A test that omits the lookup reads
          # the application server's snapshot, so its camera id must not be
          # one of the fixture's.
          {Cairn.PipelineOwner,
           [camera: cam, config: config] ++ Keyword.get(opts, :owner_opts, [])},
          {Cairn.RTPHub, camera_id: cam.id}
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp bridge(%{ingest: :ffmpeg} = cam, config),
    do: [{Cairn.FFmpegPort, camera: cam, config: config}]

  defp bridge(_cam, _config), do: []
end
