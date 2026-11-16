defmodule Cairn.Stage.FrameMetaTest do
  use ExUnit.Case, async: true

  alias Cairn.Stage.FrameMeta

  @meta %{orig_width: 1920, orig_height: 1080, observed_at_ms: 1, stream_epoch: 3}

  test "a map with every required key is the contract; motion is optional" do
    assert FrameMeta.fetch(@meta) == {:ok, @meta}
    assert {:ok, _} = FrameMeta.fetch(Map.put(@meta, :motion, nil))
    # a producer with nothing to tag still owes the key
    assert {:ok, _} = FrameMeta.fetch(%{@meta | stream_epoch: nil})
  end

  test "a missing required key is :error, never a raise" do
    for key <- FrameMeta.required_keys() do
      assert FrameMeta.fetch(Map.delete(@meta, key)) == :error
    end

    assert FrameMeta.fetch(nil) == :error
  end
end
