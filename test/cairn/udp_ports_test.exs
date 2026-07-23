defmodule Cairn.UDPPortsTest do
  use ExUnit.Case, async: true

  alias Cairn.{Config, UDPPorts}

  test "positional allocation: base + 2i / base + 2i + 1" do
    config = %Config{udp_base_port: 17_000}

    assert UDPPorts.ports_for(config, 0) == {17_000, 17_001}
    assert UDPPorts.ports_for(config, 1) == {17_002, 17_003}
    assert UDPPorts.ports_for(config, 7) == {17_014, 17_015}
  end
end
