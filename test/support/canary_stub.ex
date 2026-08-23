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

  def cpu_baseline(config, passes, opts) do
    control = :persistent_term.get(Cairn.NativeStub.control(), %{})
    if pid = control[:test], do: send(pid, {:cpu_baseline, config, passes, opts})

    case Map.get(control, :cpu_baseline) do
      fun when is_function(fun, 2) -> fun.(config, passes)
      nil -> {:ok, 45.0}
      result -> result
    end
  end
end
