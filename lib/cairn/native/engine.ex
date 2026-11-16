defmodule Cairn.Native.Engine do
  @moduledoc """
  Holds `Cairn.Native` to `Cairn.Stage.DecoderNif`, the contract
  `Cairn.Native.Host` drives a decode library through — `Cairn.Native` on a
  node that has the library, a stub (`Cairn.NativeStub`) in the suites CI runs
  without a Rust toolchain.

  The stub is why this exists. Every call the host makes is dynamic — the module
  is a term in its state — and the real module's shapes are only ever executed
  by `:native_parity`, which is excluded from any run with no library. So
  nothing else fails when the two drift apart: the stub declares the behaviour
  (a warning when it stops matching, fatal under the `--warnings-as-errors` CI
  compiles), and `__after_compile__/2` holds `Cairn.Native` to it outright.
  `CairnOrt.Engine` does the same for the inference half.
  """

  @after_compile __MODULE__

  # Asserted from this side rather than declared on `Cairn.Native`, so that the
  # module holding the seam is the one that fails when the seam moves; and
  # from the base, because `cairn_stage` cannot name a base module.
  @doc false
  def __after_compile__(_env, _bytecode),
    do: assert_exports!(Cairn.Native, Cairn.Stage.DecoderNif)

  @doc false
  def assert_exports!(module, behaviour) do
    # `function_exported?/3` answers for a *loaded* module, and mid-compile
    # `module` is not reliably either yet.
    Code.ensure_compiled!(module)
    Code.ensure_loaded!(module)

    case Enum.reject(behaviour.behaviour_info(:callbacks), fn {name, arity} ->
           function_exported?(module, name, arity)
         end) do
      [] ->
        :ok

      missing ->
        raise "#{inspect(module)} no longer exports " <>
                Enum.map_join(missing, ", ", fn {name, arity} -> "#{name}/#{arity}" end) <>
                " — every stub written against #{inspect(behaviour)} now stands in for nothing"
    end
  end
end
