defmodule Cairn.Native.Engine do
  @moduledoc """
  What `Cairn.Native.Host` reaches the NIF through: `Cairn.Native` on a node
  that has the library, a stub (`Cairn.NativeStub`) in the suites CI runs
  without a Rust toolchain.

  The stub is why this exists. Every call the host makes is dynamic — the module
  is a term in its state — and the real module's shapes are only ever executed
  by `:native_parity`, which is excluded from any run with no library. So
  nothing else fails when the two drift apart: the callbacks below hold the stub
  to the contract (a behaviour warning, fatal under the `--warnings-as-errors`
  CI compiles), and `__after_compile__/2` holds `Cairn.Native` to it outright.
  """

  @callback available?() :: boolean()
  @callback load_error() :: term() | nil
  @callback open_decoder(String.t(), map()) ::
              {:ok, reference()} | {:error, {atom(), String.t()}}
  @callback decode_au(reference(), binary(), integer(), boolean()) ::
              {:ok, {boolean(), Cairn.Native.decoded_frame() | nil}}
              | {:error, {atom(), String.t()}}
  @callback close_decoder(reference()) :: {:ok, boolean()} | {:error, {atom(), String.t()}}

  @after_compile __MODULE__

  # Asserted from this side rather than declared on `Cairn.Native`, so that the
  # module describing the seam is the one that fails when the seam moves.
  @doc false
  def __after_compile__(env, _bytecode) do
    # `function_exported?/3` answers for a *loaded* module, and mid-compile
    # `Cairn.Native` is not reliably either yet.
    Code.ensure_compiled!(Cairn.Native)
    Code.ensure_loaded!(Cairn.Native)

    case Enum.reject(env.module.behaviour_info(:callbacks), fn {name, arity} ->
           function_exported?(Cairn.Native, name, arity)
         end) do
      [] ->
        :ok

      missing ->
        raise "Cairn.Native no longer exports " <>
                Enum.map_join(missing, ", ", fn {name, arity} -> "#{name}/#{arity}" end) <>
                " — every stub written against this behaviour now stands in for nothing"
    end
  end
end
