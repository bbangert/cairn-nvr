defmodule Cairn.CanaryStub do
  @moduledoc """
  Stands in for `Cairn.Native.Canary`, whose probe is a real OS process running
  the plugin binary. Reads the same control map `Cairn.NativeStub` does.
  """

  @behaviour Cairn.Native.Canary

  @impl true
  def probe(config, opts) do
    control = :persistent_term.get(Cairn.NativeStub.control(), %{})
    if pid = control[:test], do: send(pid, {:canary, config, opts})
    Map.get(control, :canary, :ok)
  end
end
