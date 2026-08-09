defmodule Cairn.Camera do
  @moduledoc """
  Per-camera supervision tree (`:rest_for_one`).

  Child order: `RingBuffer` -> `FFmpegPort` -> (`PluginPort`) -> (`RTPHub`).
  Ring death restarts ffmpeg (a fresh ring is empty anyway); ffmpeg death
  restarts only its downstream consumers.

  Only a *classic* camera with an inline plugin command owns a `PluginPort`;
  cameras served by a named plugin group are just Ring -> FFmpeg -> RTPHub
  here. A membrane camera has no plugin port and no UDP ports at all: its
  detections come from the in-VM NIF at the end of its pipeline's detect
  branch and its hub is fed by that pipeline's RTP branch, so a plugin port
  running alongside would be a second producer feeding the same tracker from
  the same video.
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
        [{Cairn.RTPHub, camera_id: cam.id, port: rtp_hub_port(cam, config, index)}]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # Allocation is positional and stays that way: a membrane camera keeps its
  # index slot unused rather than being skipped, because skipping would
  # renumber every camera after it and move ports the classic stack has
  # sockets bound to — on a live reload, for a neighbour's edit.
  defp rtp_hub_port(%{pipeline: :membrane}, _config, _index), do: nil

  defp rtp_hub_port(_cam, config, index) do
    {_plugin_port, rtp_port} = Cairn.UDPPorts.ports_for(config, index)
    rtp_port
  end

  # A `{:group, _}` camera's detections come from a shared process owned by
  # `Cairn.PluginGroupSupervisor`; a membrane camera's from its own pipeline
  # (and `Cairn.Config`'s `members_for/2` keeps it out of the group too).
  defp plugin_child(%{pipeline: :membrane}, _config, _index), do: []

  defp plugin_child(%{plugin: {:inline, _argv}} = cam, config, index) do
    [{Cairn.PluginPort, camera: cam, config: config, index: index}]
  end

  defp plugin_child(_cam, _config, _index), do: []
end
