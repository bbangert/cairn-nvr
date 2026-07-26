defmodule Cairn.Camera do
  @moduledoc """
  Per-camera supervision tree (`:rest_for_one`).

  Child order: `RingBuffer` -> `FFmpegPort` -> (`PluginPort`) -> (`RTPHub`).
  Ring death restarts ffmpeg (a fresh ring is empty anyway); ffmpeg death
  restarts only the downstream consumers of its UDP outputs.

  Only a camera with an inline plugin command owns a `PluginPort`; cameras
  served by a named plugin group are just Ring -> FFmpeg -> RTPHub here.
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
        plugin_child(cam, config, index) ++
        [{Cairn.RTPHub, camera_id: cam.id, port: rtp_port}]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # A `{:group, _}` camera's detections come from a shared process owned by
  # `Cairn.PluginGroupSupervisor`, not from this tree.
  defp plugin_child(%{plugin: {:inline, _argv}} = cam, config, index) do
    [{Cairn.PluginPort, camera: cam, config: config, index: index}]
  end

  defp plugin_child(_cam, _config, _index), do: []
end
