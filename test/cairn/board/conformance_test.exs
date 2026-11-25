defmodule Cairn.Board.ConformanceTest do
  use ExUnit.Case, async: true

  alias Cairn.Board.Loader
  alias Cairn.Pipeline.DetectChain
  alias Cairn.Stage.Conformance

  # On the base's own steps, as the loader checks it, so a board that keeps
  # them is checked on them too.
  test "the generic board conforms" do
    opts = [
      generic: DetectChain.base_steps("conformance"),
      requires: Loader.requires(),
      base: Cairn.Board.base()
    ]

    assert Conformance.check(Cairn.Board.Generic, opts) == :ok
  end
end
