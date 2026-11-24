defmodule Cairn.FixtureBoard.Board do
  @moduledoc """
  A board that names no hardware, built apart from the base the way a
  vendor board is, so the base can test loading one from a board directory.

  `decoder: fake` replaces the base's decode step with `FakeDecode`;
  `backend: fake` is experimental, and its conversion of `yolov10` is
  unproven. `ort`, `auto` and `sw` are the base's own libraries, named here
  by module until the base lends them through the contract.
  """

  @behaviour Cairn.Stage.Board

  alias Cairn.FixtureBoard.{FakeDecode, Native}
  alias Cairn.Stage.Step

  @impl true
  def name, do: "fixture"

  @impl true
  def detect_chain(%{decoder: "fake"} = context) do
    decode = %Step{
      name: :decoder,
      element: FakeDecode,
      covers: [:decode, :scale],
      input: :h264,
      output: :rgb
    }

    [decode | Enum.reject(context.generic, &(:decode in &1.covers))]
  end

  def detect_chain(context), do: context.generic

  @impl true
  def decoders, do: ~w(auto sw fake)

  @impl true
  def backends do
    %{
      "ort" => %{
        artifact: "onnx",
        fused_nms: true,
        dynamic_shapes: true,
        cpu_twin: false,
        experimental: false
      },
      "fake" => %{
        artifact: "fake",
        fused_nms: true,
        dynamic_shapes: true,
        cpu_twin: false,
        experimental: true,
        conversions: %{
          evidence: "test/fixture_board",
          contracts: %{"yolox" => :proven, "yolov10" => {:unproven, "the fixture says so"}}
        }
      }
    }
  end

  @impl true
  def decoder_backend("fake"), do: Native
  def decoder_backend(_decoder), do: Cairn.Native

  @impl true
  def engine("fake"), do: %{module: Native, canary: "cairn-fixture-probe"}
  def engine(_backend), do: %{module: CairnOrt, canary: "cairn-detect"}

  @impl true
  def preflight, do: %{decoders: %{}, backends: %{}}

  @impl true
  def artifacts(_context), do: []

  @impl true
  def profiles_dir, do: Application.app_dir(:cairn_fixture_board, "priv/profiles")
end
