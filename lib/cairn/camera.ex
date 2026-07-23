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

    {_plugin_port, rtp_port} = Cairn.UDPPorts.ports_for(config, index)

    children =
      [
        %{
          id: :probe,
          start: {Task, :start_link, [Cairn.Probe, :run_and_store, [cam]]},
          restart: :temporary
        },
        {Cairn.RingBuffer, camera_id: cam.id, pre_window_seconds: windows.pre},
        {Cairn.FFmpegPort, camera: cam, config: config, index: index}
      ] ++
        if cam.plugin do
          [{Cairn.PluginPort, camera: cam, config: config, index: index}]
        else
          []
        end ++
        [{Cairn.RTPHub, camera_id: cam.id, port: rtp_port}]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
