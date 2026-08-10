defmodule CairnOrt.Engine do
  @moduledoc """
  What `Cairn.Native.Host` reaches the inference NIF through: `CairnOrt` on a
  node that has the library, a stub (`Cairn.CairnOrtStub`) in the suites CI
  runs without a Rust toolchain.

  The decode half's counterpart is `Cairn.Native.Engine`; see that module for
  why the seam is asserted from this side (`__after_compile__/2` holds
  `CairnOrt` to the contract outright, and the behaviour holds every stub to
  it under `--warnings-as-errors`).
  """

  @callback available?() :: boolean()
  @callback load_error() :: term() | nil
  @callback init(map()) :: {:ok, reference()} | {:error, {atom(), String.t()}}
  @callback engine_spec(reference()) :: CairnOrt.input_spec()
  @callback open_stream(reference(), String.t(), map()) ::
              {:ok, reference()} | {:error, {atom(), String.t()}}
  @callback push_frame(reference(), binary(), CairnOrt.frame_meta(), {integer(), integer()}) ::
              {:ok, {[map()], [String.t()]}} | {:error, {atom(), String.t()}}
  @callback close_stream(reference()) :: {:ok, boolean()} | {:error, {atom(), String.t()}}
  @callback cpu_baseline_ms(map(), pos_integer()) ::
              {:ok, float()} | {:error, {atom(), String.t()}}

  @after_compile __MODULE__

  # Asserted from this side rather than declared on `CairnOrt`, so that the
  # module describing the seam is the one that fails when the seam moves.
  @doc false
  def __after_compile__(env, _bytecode) do
    # `function_exported?/3` answers for a *loaded* module, and mid-compile
    # `CairnOrt` is not reliably either yet.
    Code.ensure_compiled!(CairnOrt)
    Code.ensure_loaded!(CairnOrt)

    case Enum.reject(env.module.behaviour_info(:callbacks), fn {name, arity} ->
           function_exported?(CairnOrt, name, arity)
         end) do
      [] ->
        :ok

      missing ->
        raise "CairnOrt no longer exports " <>
                Enum.map_join(missing, ", ", fn {name, arity} -> "#{name}/#{arity}" end) <>
                " — every stub written against this behaviour now stands in for nothing"
    end
  end
end
