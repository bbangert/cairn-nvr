defmodule Cairn.Camera do
  @moduledoc """
  Per-camera supervision tree (`:rest_for_one`).

  Child order: `RingBuffer` -> `FFmpegPort` -> `RTPHub`. Ring death restarts
  the ingest (a fresh ring is empty anyway); ingest death restarts only its
  downstream consumers.

  Detection is not in this tree: the camera's pipeline feeds the node's one
  in-VM engine (`Cairn.Native.Host`) at the end of its detect branch, and
  its hub is fed by that pipeline's RTP branch — both owned per-session by
  `Cairn.FFmpegPort`, so a supervisor restart cannot decouple a session
  from the pipeline born with it.
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

    children = [
      %{
        id: :probe,
        start: {Task, :start_link, [Cairn.Probe, :run_and_store, [cam]]},
        restart: :temporary
      },
      {Cairn.RingBuffer, camera_id: cam.id, pre_window_seconds: windows.pre},
      {Cairn.FFmpegPort, camera: cam, config: config},
      {Cairn.RTPHub, camera_id: cam.id}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
