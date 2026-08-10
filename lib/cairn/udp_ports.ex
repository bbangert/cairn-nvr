defmodule Cairn.UDPPorts do
  @moduledoc """
  Pure positional UDP port allocator: camera index -> `{plugin_port,
  rtp_port}` = `{base + 4i, base + 4i + 2}`. Range exhaustion is rejected
  at config validation time (`Cairn.Config`).

  Each camera gets a block of four rather than two because an RTP receiver
  conventionally also binds `port + 1` for RTCP. Handing out adjacent ports
  made the WebRTC tap sit on the plugin's RTCP port, and a standards-compliant
  receiver (ffmpeg's SDP demuxer, GStreamer's udpsrc pair, ...) then fails to
  open the stream at all. Cairn itself sends no RTCP; the odd ports are
  reserved purely so plugins can bind them.

  A membrane camera consumes no ports but still holds its slot: renumbering
  around it would move every later camera's ports, which on a live reload
  means unbinding sockets over an unrelated camera's edit.
  """

  alias Cairn.Config

  @ports_per_camera 4

  @doc "Ports consumed per camera — see the moduledoc for why it is 4, not 2."
  @spec ports_per_camera() :: pos_integer()
  def ports_per_camera, do: @ports_per_camera

  @spec ports_for(Config.t(), non_neg_integer()) ::
          {plugin_port :: pos_integer(), rtp_port :: pos_integer()}
  def ports_for(%Config{udp_base_port: base}, index) when is_integer(base) do
    block = base + @ports_per_camera * index
    {block, block + 2}
  end
end
