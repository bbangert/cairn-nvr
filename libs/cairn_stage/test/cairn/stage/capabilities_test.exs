defmodule Cairn.Stage.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Cairn.Stage.Capabilities

  @base %{artifact: "x", fused_nms: false, dynamic_shapes: false, cpu_twin: false}
  @converted Map.put(@base, :conversions, %{
               evidence: "docs/x.md",
               contracts: %{"yolox" => :proven, "rfdetr" => {:unproven, "no op"}}
             })

  test "a backend is experimental unless its board says otherwise" do
    assert Capabilities.experimental?(@base)
    assert Capabilities.experimental?(Map.put(@base, :experimental, true))
    refute Capabilities.experimental?(Map.put(@base, :experimental, false))
  end

  test "only an explicit false is not experimental" do
    for value <- [nil, "false", 0] do
      assert Capabilities.experimental?(Map.put(@base, :experimental, value))
    end
  end

  test "without conversions every contract is proven, with no evidence" do
    assert Capabilities.conversion(@base, "rfdetr") == :proven
    assert Capabilities.evidence(@base) == nil
  end

  test "with conversions, a contract is what the board lists, and unproven when unlisted" do
    assert Capabilities.conversion(@converted, "yolox") == :proven
    assert Capabilities.conversion(@converted, "rfdetr") == {:unproven, "no op"}
    assert Capabilities.conversion(@converted, "yolov8") == {:unproven, "not listed by the board"}
    assert Capabilities.evidence(@converted) == "docs/x.md"
  end

  test "conversions without a contracts map make every contract unproven" do
    for conversions <- [%{evidence: "docs/x.md"}, %{evidence: "docs/x.md", contracts: nil}, nil] do
      caps = Map.put(@base, :conversions, conversions)
      assert Capabilities.conversion(caps, "yolox") == {:unproven, "not listed by the board"}
    end
  end

  test "a verdict outside the type is unproven" do
    caps =
      Map.put(@base, :conversions, %{evidence: "docs/x.md", contracts: %{"yolox" => :unproven}})

    assert Capabilities.conversion(caps, "yolox") == {:unproven, "not listed by the board"}
  end

  test "conversions naming no evidence have none" do
    assert Capabilities.evidence(Map.put(@base, :conversions, %{contracts: %{}})) == nil
    assert Capabilities.evidence(Map.put(@base, :conversions, nil)) == nil
  end
end
