defmodule Cairn.Camera do
  @moduledoc """
  Per-camera supervision tree (`:rest_for_one`).

  Child order: `RingBuffer` -> `FFmpegPort` -> (`PluginPort`) -> (`RTPHub`).
  Ring death restarts ffmpeg (a fresh ring is empty anyway); ffmpeg death
  restarts only the downstream consumers of its UDP outputs.
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
    index = Keyword.fetch!(opts, :index)
    windows = Cairn.Config.windows(config, cam)

    children = [
      {Cairn.RingBuffer, camera_id: cam.id, pre_window_seconds: windows.pre},
      {Cairn.FFmpegPort, camera: cam, config: config, index: index}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
