defmodule Cairn.Board.ConformanceTest do
  use ExUnit.Case, async: true

  alias Cairn.Pipeline.{Decoder, Inference}
  alias Cairn.Stage.{Conformance, Step}

  # The base's own steps, as `Cairn.Pipeline.DetectChain` hands them over, so
  # a board that keeps them is checked on them too. In CI's rockchip subset
  # too, where the built-in board is Rockchip's.
  @generic [
    %Step{
      name: :decoder,
      element: Decoder,
      covers: [:decode, :scale],
      input: :h264,
      output: :rgb
    },
    %Step{name: :infer, element: Inference, covers: [:infer], input: :rgb, output: :detections}
  ]

  test "the built-in board conforms" do
    assert Conformance.check(Cairn.Board.module(), generic: @generic) == :ok
  end
end
