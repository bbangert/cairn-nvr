defmodule Driver.Board.Ssh do
  @moduledoc """
  The one ssh exec left in the driver: asking nerves_ssh to evaluate
  `Vagus.Dist.enable()`. Returns the raw channel output — parsing (and
  the `\\r\\n` it rides in on) is `Driver.Board.parse_enable/1`'s job,
  so tests can feed recorded output without shelling out.
  """

  @callback enable(host :: String.t()) :: {:ok, raw :: String.t()} | {:error, term()}

  defmodule Cmd do
    @moduledoc false
    @behaviour Driver.Board.Ssh

    @impl true
    def enable(host) do
      args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, "Vagus.Dist.enable()"]

      case System.cmd("ssh", args, stderr_to_stdout: true) do
        {out, 0} -> {:ok, out}
        {out, rc} -> {:error, {:ssh_failed, rc, out}}
      end
    end
  end
end
