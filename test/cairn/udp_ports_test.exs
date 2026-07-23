defmodule Cairn.UDPPortsTest do
  use ExUnit.Case, async: true

  alias Cairn.{Config, UDPPorts}

  test "positional allocation: base + 4i / base + 4i + 2" do
    config = %Config{udp_base_port: 17_000}

    assert UDPPorts.ports_for(config, 0) == {17_000, 17_002}
    assert UDPPorts.ports_for(config, 1) == {17_004, 17_006}
    assert UDPPorts.ports_for(config, 7) == {17_028, 17_030}
  end

  test "leaves port + 1 free on both taps for RTCP" do
    config = %Config{udp_base_port: 17_000}

    # An RTP receiver also binds port+1; if any allocated port lands on
    # another's RTCP port the plugin's demuxer cannot open the stream.
    allocated =
      Enum.flat_map(0..7, fn i ->
        {plugin, rtp} = UDPPorts.ports_for(config, i)
        [plugin, rtp]
      end)

    rtcp = Enum.map(allocated, &(&1 + 1))

    assert MapSet.disjoint?(MapSet.new(allocated), MapSet.new(rtcp))
  end
end
