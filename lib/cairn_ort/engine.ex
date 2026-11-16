defmodule CairnOrt.Engine do
  @moduledoc """
  Holds `CairnOrt` to `Cairn.Stage.EngineNif`, the contract
  `Cairn.Native.Host` drives an inference library through — `CairnOrt` on a
  node that has the library, a stub (`Cairn.CairnOrtStub`) in the suites CI
  runs without a Rust toolchain. Why the check is made from outside the NIF
  module is `Cairn.Native.Engine`'s note.
  """

  alias Cairn.Native.Engine

  @after_compile __MODULE__

  @doc false
  def __after_compile__(_env, _bytecode),
    do: Engine.assert_exports!(CairnOrt, Cairn.Stage.EngineNif)
end
