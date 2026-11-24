defmodule Cairn.Pipeline.DetectChainTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec

  alias Cairn.Config.Camera
  alias Cairn.Motion
  alias Cairn.Pipeline.{Decoder, DetectChain, Inference, MotionGate, Picker}
  alias Cairn.Stage.Step

  # Rewrites the generic chain with the function the test passes in the
  # stream params, which reach a board untouched.
  defmodule ScriptedBoard do
    @moduledoc false
    def name, do: "scripted"
    def detect_chain(%{stream_params: %{chain: chain}, generic: generic}), do: chain.(generic)
  end

  defmodule DecoderBoard do
    @moduledoc false
    def name, do: "decoder"

    def detect_chain(%{decoder: decoder, generic: generic, base: base}) do
      send(self(), {:decoder, decoder, base})
      generic
    end
  end

  @camera %Camera{id: "cam"}
  @motion ~s({"enabled":true,"threshold":30})
  @seam [target_queue_size: 1, min_demand_factor: 0.5]

  defp head, do: get_child(:tagger)

  # The branch as `Cairn.Pipeline.Camera` linked it before the board seam, by hand.
  defp by_hand(params, gate) do
    head()
    |> child(:picker, Picker)
    |> via_in(:input, @seam)
    |> child(:decoder, %Decoder{
      camera_id: "cam",
      stream_params: if(gate, do: %{params | motion_json: nil}, else: params)
    })
    |> then(fn link ->
      if gate, do: link |> via_in(:input, @seam) |> child(:motion_gate, gate), else: link
    end)
    |> via_in(:input, @seam)
    |> child(:infer, %Inference{
      session: {Cairn.Native.Host, Cairn.Native.Host},
      stream_id: "cam",
      stream_params: params
    })
  end

  describe "the generic board" do
    test "builds the ungated branch exactly as it was linked by hand" do
      params = %{min_score: %{"person" => 0.6}, motion_json: nil}

      assert DetectChain.build(head(), @camera, stream_params: params) == by_hand(params, nil)
    end

    test "builds the gated branch exactly as it was linked by hand" do
      params = %{min_score: %{}, motion_json: @motion}
      {:ok, config} = Motion.Config.resolve_json(@motion)

      assert DetectChain.build(head(), @camera, stream_params: params) ==
               by_hand(params, %MotionGate{config: config})
    end
  end

  test "the detect opts' decoder reaches the board, nil when absent, with the base's libraries" do
    params = %{min_score: %{}, motion_json: nil}
    DetectChain.build(head(), @camera, [stream_params: params, decoder: "sw"], DecoderBoard)
    assert_received {:decoder, "sw", base}
    assert base == Cairn.Board.base()

    DetectChain.build(head(), @camera, [stream_params: params], DecoderBoard)
    assert_received {:decoder, nil, _base}
  end

  describe "a board's chain is checked before anything is built" do
    defp refuse(params, chain, pattern) do
      params = Map.put(params, :chain, chain)

      error =
        assert_raise ArgumentError, fn ->
          DetectChain.build(head(), @camera, [stream_params: params], ScriptedBoard)
        end

      assert error.message =~ "camera cam: board scripted's detect chain"
      assert error.message =~ pattern
    end

    test "a missing stage" do
      refuse(%{motion_json: @motion}, &List.delete_at(&1, 1), "no step covers :motion")
    end

    test "a stage covered twice" do
      twice = fn [%Step{} = decoder, infer] ->
        [decoder, %Step{decoder | name: :rescale, covers: [:scale], input: :rgb}, infer]
      end

      refuse(%{}, twice, "step :rescale covers :scale, already covered by :decoder")
    end

    test "mismatched formats" do
      mismatch = fn [decoder, %Step{} = infer] -> [decoder, %Step{infer | input: :dma_frame}] end
      refuse(%{}, mismatch, "step :decoder emits :rgb but :infer takes :dma_frame")
    end
  end
end
