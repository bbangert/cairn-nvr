defmodule Cairn.Camera do
  @moduledoc """
  Per-camera supervision tree (`:rest_for_one`).

  Child order: `RingBuffer` -> (`FFmpegPort`, bridge cameras only) ->
  `PipelineOwner` -> `RTPHub` (plus a `:temporary` probe task ahead of them,
  outside the restart chain this order describes). Ring death restarts the
  ingest (a fresh ring is empty anyway); ingest death restarts only its
  downstream consumers.

  `FFmpegPort` sits above the owner because the pipeline consumes its bytes:
  the restart chain follows the media, so a port that died mid-session — never
  having cut it in band — takes the pipeline holding that half-session with it.
  A camera on `ingest: rtsp` has no port at all: its sessions live inside
  `Membrane.RTSPDualStream.Source`.

  Detection is not in this tree: the camera's pipeline feeds the node's one
  in-VM engine (`Cairn.Native.Host`) at the end of its detect branch, and its
  hub is fed by that pipeline's RTP branch. The pipeline is long-lived and
  rebuilt only by `Cairn.PipelineOwner`, so neither branch is rebuilt by a
  reconnect and a supervisor restart cannot decouple the two.
  """

  use Supervisor

  def start_link(opts) do
    cam = Keyword.fetch!(opts, :camera)
    Supervisor.start_link(__MODULE__, opts, name: Cairn.Registry.via(cam.id, :camera))
  end

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
          {Cairn.PipelineOwner, camera: cam, config: config},
          {Cairn.RTPHub, camera_id: cam.id}
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp bridge(%{ingest: :ffmpeg} = cam, config),
    do: [{Cairn.FFmpegPort, camera: cam, config: config}]

  defp bridge(_cam, _config), do: []
end
