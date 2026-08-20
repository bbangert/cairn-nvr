defmodule Cairn.LiveDetectionsTest do
  use ExUnit.Case, async: true

  alias Cairn.LiveDetections

  defp object(attrs) do
    Map.merge(
      %{
        label: "person",
        score: 0.9,
        bbox: [0.1, 0.2, 0.3, 0.4],
        track_id: nil,
        observation_kind: "detected"
      },
      Map.new(attrs)
    )
  end

  test "the topic is one per camera" do
    assert LiveDetections.topic("front_door") == "camera:front_door:detections"
    refute LiveDetections.topic("a") == LiveDetections.topic("b")
  end

  test "a subscriber gets the camera it asked for and no other" do
    LiveDetections.subscribe("cam_one")

    LiveDetections.broadcast("cam_two", [%{label: "car", score: 0.7, bbox: [0.0, 0.0, 1.0, 1.0]}])

    LiveDetections.broadcast("cam_one", [
      %{label: "person", score: 0.9, bbox: [0.1, 0.1, 0.2, 0.2]}
    ])

    assert_receive {:detections, "cam_one", [%{label: "person"}]}
    refute_received {:detections, "cam_two", _}
  end

  test "an empty list is a message, not a silence — it is how boxes go away" do
    LiveDetections.subscribe("cam_empty")

    LiveDetections.broadcast("cam_empty", [%{label: "person", score: 0.9, bbox: [0, 0, 1, 1]}])
    LiveDetections.broadcast("cam_empty", [])

    assert_receive {:detections, "cam_empty", [_one]}
    assert_receive {:detections, "cam_empty", []}
  end

  test "unsubscribing stops delivery" do
    LiveDetections.subscribe("cam_bye")
    LiveDetections.unsubscribe("cam_bye")
    LiveDetections.broadcast("cam_bye", [])

    refute_received {:detections, "cam_bye", _}
  end

  # Node-locality itself is not observable from one node — both modes deliver
  # to every local subscriber — so this proves the weaker, checkable thing and
  # its name says so. What it defends is real: the boxes are drawn over a
  # video served by THIS node, and a cluster-wide broadcast would ship every
  # camera's frames to every node for subscribers with no frame to put them
  # on. A rename upstream or a second call site behind a helper would slip
  # past it; there is no single-node test that would not.
  test "the broadcast is written as local_broadcast — a single node cannot observe the difference" do
    source = File.read!("lib/cairn/live_detections.ex")

    assert source =~ "Phoenix.PubSub.local_broadcast"
    refute source =~ ~r/Phoenix\.PubSub\.broadcast\(/
  end

  # The consumer's replace semantics are pinned in dashboard_live_test; this
  # is the same contract one layer down, where the lists genuinely differ
  # rather than one of them being empty.
  test "a second non-empty list arrives whole, with nothing carried over" do
    LiveDetections.subscribe("cam_swap")

    LiveDetections.broadcast("cam_swap", [
      %{label: "person", score: 0.9, bbox: [0.1, 0.1, 0.2, 0.2]},
      %{label: "dog", score: 0.6, bbox: [0.3, 0.3, 0.1, 0.1]}
    ])

    LiveDetections.broadcast("cam_swap", [%{label: "car", score: 0.8, bbox: [0.5, 0.5, 0.2, 0.2]}])

    assert_received {:detections, "cam_swap", [%{label: "person"}, %{label: "dog"}]}
    assert_received {:detections, "cam_swap", [%{label: "car", score: 0.8}]}
    refute_received {:detections, "cam_swap", _}
  end

  describe "from_objects/1" do
    test "a detected object with a box becomes a drawable detection" do
      assert LiveDetections.from_objects([object(label: "car", score: 0.42)]) ==
               [%{label: "car", score: 0.42, bbox: [0.1, 0.2, 0.3, 0.4]}]
    end

    test "a predictor's guess earns no box" do
      assert LiveDetections.from_objects([object(observation_kind: "tracked")]) == []
    end

    test "an object with no usable box is dropped, not drawn at the origin" do
      objects = [
        object(bbox: nil),
        object(bbox: []),
        object(bbox: [0.1, 0.2, 0.3]),
        Map.delete(object([]), :bbox)
      ]

      assert LiveDetections.from_objects(objects) == []
    end

    # The overlay's whole job is showing what the model reported; an operator
    # tuning `min_score` has to be able to see the detections it is rejecting.
    test "a score below any plausible floor still draws" do
      assert [%{score: 0.05}] = LiveDetections.from_objects([object(score: 0.05)])
    end

    test "order is the frame's order and nothing is folded per label" do
      objects = [object(label: "person"), object(label: "car"), object(label: "person")]

      assert ["person", "car", "person"] =
               objects |> LiveDetections.from_objects() |> Enum.map(& &1.label)
    end

    test "an empty frame yields an empty list" do
      assert LiveDetections.from_objects([]) == []
    end
  end
end
