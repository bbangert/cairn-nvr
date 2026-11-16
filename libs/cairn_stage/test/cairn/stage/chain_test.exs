defmodule Cairn.Stage.ChainTest do
  use ExUnit.Case, async: true

  alias Cairn.Stage.{Chain, Step}

  defp step(name, covers, input, output),
    do: %Step{name: name, element: name, covers: covers, input: input, output: output}

  defp decoder, do: step(:decoder, [:decode, :scale], :h264, :rgb)
  defp gate, do: step(:motion_gate, [:motion], :rgb, :rgb)
  defp infer, do: step(:infer, [:infer], :rgb, :detections)

  defp refused(steps, required, pattern) do
    assert {:error, message} = Chain.validate(steps, required)
    assert message =~ pattern
    message
  end

  test "required stages: motion only when a gate is configured" do
    assert Chain.required(true) == [:decode, :scale, :motion, :infer]
    assert Chain.required(false) == [:decode, :scale, :infer]
  end

  test "the generic chains pass, with and without a gate" do
    assert Chain.validate([decoder(), gate(), infer()], Chain.required(true)) == :ok
    assert Chain.validate([decoder(), infer()], Chain.required(false)) == :ok
    # a gate nobody required is still a well-formed chain
    assert Chain.validate([decoder(), gate(), infer()], Chain.required(false)) == :ok
  end

  test "a fused step and an adapter step" do
    fused = step(:decode_scale, [:decode, :scale], :h264, :dma_frame)
    adapter = step(:download, [], :dma_frame, :rgb)

    assert Chain.validate([fused, adapter, infer()], Chain.required(false)) == :ok
  end

  test "a missing required stage names the steps there are" do
    message =
      refused([step(:decoder, [:decode], :h264, :rgb), infer()], [:decode, :scale], ":scale")

    assert message =~ ":decoder"
  end

  test "a configured gate the board dropped is refused" do
    message = refused([decoder(), infer()], Chain.required(true), ":motion")
    assert message =~ ":infer"
  end

  test "a stage covered twice names the second step and the first" do
    twice = step(:scaler, [:scale], :rgb, :rgb)

    message =
      refused([decoder(), twice, infer()], Chain.required(false), "step :scaler covers :scale")

    assert message =~ ":decoder"
  end

  test "stages out of order name the step that comes too late" do
    late = step(:late_decode, [:decode], :rgb, :detections)
    early = step(:early, [:scale, :infer], :h264, :rgb)

    refused([early, late], Chain.required(false), "step :late_decode covers :decode after :early")
  end

  test "an unknown stage is refused" do
    refused([step(:decoder, [:decode, :scale, :colour], :h264, :rgb), infer()], [], ":colour")
  end

  test "mismatched adjacent formats name both steps and both formats" do
    dma_infer = step(:infer, [:infer], :dma_frame, :detections)
    message = refused([decoder(), dma_infer], Chain.required(false), "step :decoder emits :rgb")
    assert message =~ ":infer takes :dma_frame"
  end

  test "the chain must start at :h264 and end at :detections" do
    refused(
      [step(:decoder, [:decode, :scale], :rgb, :rgb), infer()],
      [],
      "step :decoder takes :rgb, not :h264"
    )

    refused(
      [decoder(), step(:infer, [:infer], :rgb, :rgb)],
      [],
      "step :infer emits :rgb, not :detections"
    )
  end

  test "duplicate names are refused" do
    refused([decoder(), step(:decoder, [:infer], :rgb, :detections)], [], "step :decoder appears")
  end

  test "an empty chain or a non-step is refused" do
    refused([], [], "non-empty")
    refused([%{name: :x}], [], "%Cairn.Stage.Step{}")
  end
end
