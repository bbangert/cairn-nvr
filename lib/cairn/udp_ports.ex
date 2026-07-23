defmodule Cairn.UDPPorts do
  @moduledoc """
  Pure positional UDP port allocator: camera index -> `{plugin_port,
  rtp_port}` = `{base + 2i, base + 2i + 1}`. Range exhaustion is rejected
  at config validation time (`Cairn.Config`).
  """

  alias Cairn.Config

  @spec ports_for(Config.t(), non_neg_integer()) ::
          {plugin_port :: pos_integer(), rtp_port :: pos_integer()}
  def ports_for(%Config{udp_base_port: base}, index) when is_integer(base) do
    {base + 2 * index, base + 2 * index + 1}
  end
end
