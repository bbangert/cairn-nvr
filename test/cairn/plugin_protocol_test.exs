defmodule Cairn.PluginProtocolTest do
  use ExUnit.Case, async: true

  alias Cairn.PluginProtocol

  @base %{"label" => "person", "score" => 0.9, "bbox" => [0, 0, 1, 1]}

  defp det(fields), do: Map.merge(@base, fields)

  @valid [
    {"floats throughout", %{"score" => 0.87, "bbox" => [0.12, 0.4, 0.2, 0.5]}},
    {"integer score 0", %{"score" => 0}},
    {"integer score 1", %{"score" => 1}},
    {"integer bbox at the bounds", %{"bbox" => [0, 0, 1, 1]}},
    {"single-byte label", %{"label" => "a"}},
    {"64-byte label", %{"label" => String.duplicate("a", 64)}},
    {"multibyte label under 64 bytes", %{"label" => String.duplicate("é", 32)}}
  ]

  @invalid [
    {"empty label", %{"label" => ""}},
    {"label over 64 bytes", %{"label" => String.duplicate("a", 65)}},
    {"multibyte label over 64 bytes", %{"label" => String.duplicate("é", 33)}},
    {"non-binary label", %{"label" => 12}},
    {"nil label", %{"label" => nil}},
    {"string score", %{"score" => "0.9"}},
    {"score above 1", %{"score" => 5.0}},
    {"negative score", %{"score" => -0.1}},
    {"nil score", %{"score" => nil}},
    {"3-element bbox", %{"bbox" => [0, 0, 1]}},
    {"5-element bbox", %{"bbox" => [0, 0, 1, 1, 1]}},
    {"empty bbox", %{"bbox" => []}},
    {"non-list bbox", %{"bbox" => "0,0,1,1"}},
    {"non-numeric bbox member", %{"bbox" => [0, 0, "1", 1]}},
    {"negative bbox origin", %{"bbox" => [-0.1, 0, 0.5, 0.5]}},
    {"bbox origin above 1", %{"bbox" => [1.5, 0, 0.5, 0.5]}},
    {"bbox size above 1", %{"bbox" => [0, 0, 1.5, 0.5]}},
    {"integer bbox out of range", %{"bbox" => [0, 0, 2, 2]}},
    {"zero width", %{"bbox" => [0, 0, 0, 0.5]}},
    {"zero height", %{"bbox" => [0, 0, 0.5, 0]}},
    {"negative height", %{"bbox" => [0, 0, 0.5, -0.5]}}
  ]

  for {name, fields} <- @valid do
    test "valid: #{name}" do
      assert {:ok, det} = PluginProtocol.validate_det(det(unquote(Macro.escape(fields))))
      assert is_float(det.score)
      assert [_, _, _, _] = det.bbox
    end
  end

  for {name, fields} <- @invalid do
    test "invalid: #{name}" do
      assert PluginProtocol.validate_det(det(unquote(Macro.escape(fields)))) == :error
    end
  end

  test "keys missing entirely are invalid" do
    assert PluginProtocol.validate_det(%{"label" => "person", "score" => 0.9}) == :error
    assert PluginProtocol.validate_det(%{"score" => 0.9, "bbox" => [0, 0, 1, 1]}) == :error
    assert PluginProtocol.validate_det(%{}) == :error
  end

  test "non-map dets are invalid" do
    assert PluginProtocol.validate_det("person") == :error
    assert PluginProtocol.validate_det(nil) == :error
    assert PluginProtocol.validate_det([0, 0, 1, 1]) == :error
  end

  test "extra keys are ignored and dropped from the normalized det" do
    assert {:ok, det} = PluginProtocol.validate_det(det(%{"track_id" => 7}))
    assert det == %{label: "person", score: 0.9, bbox: [0, 0, 1, 1]}
  end

  test "validate_dets keeps the valid dets in order and counts the rest" do
    dets = [
      det(%{"label" => "a"}),
      det(%{"bbox" => [0, 0, 1]}),
      det(%{"label" => "b"}),
      det(%{"score" => "high"}),
      "garbage"
    ]

    assert {[%{label: "a"}, %{label: "b"}], 3} = PluginProtocol.validate_dets(dets)
  end

  test "validate_dets on an empty list" do
    assert PluginProtocol.validate_dets([]) == {[], 0}
  end
end
