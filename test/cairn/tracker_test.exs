defmodule Cairn.TrackerTest do
  use ExUnit.Case, async: true

  alias Cairn.Tracker

  defp det(label, bbox, score \\ 0.9), do: %{label: label, bbox: bbox, score: score}

  test "iou" do
    assert Tracker.iou([0, 0, 2, 2], [0, 0, 2, 2]) == 1.0
    assert Tracker.iou([0, 0, 2, 2], [2, 2, 2, 2]) == 0.0
    assert Tracker.iou([0, 0, 2, 2], [1, 1, 2, 2]) == 1 / 7
  end

  test "same object keeps its id across overlapping frames" do
    {t, [a]} = Tracker.track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4])])
    {_t, [b]} = Tracker.track(t, [det("person", [0.12, 0.1, 0.2, 0.4])])

    assert a.object_id == b.object_id
  end

  test "non-overlapping detection of same label gets a new id" do
    {t, [a]} = Tracker.track(Tracker.new(), [det("person", [0.0, 0.0, 0.1, 0.1])])
    {_t, [b]} = Tracker.track(t, [det("person", [0.8, 0.8, 0.1, 0.1])])

    refute a.object_id == b.object_id
  end

  test "labels never match each other even when overlapping" do
    {t, [a]} = Tracker.track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4])])
    {_t, [b]} = Tracker.track(t, [det("cat", [0.1, 0.1, 0.2, 0.4])])

    refute a.object_id == b.object_id
  end

  test "two objects tracked independently in one batch" do
    dets = [det("person", [0.1, 0.1, 0.2, 0.4]), det("person", [0.7, 0.1, 0.2, 0.4])]
    {t, [a, b]} = Tracker.track(Tracker.new(), dets)
    assert a.object_id != b.object_id

    moved = [det("person", [0.72, 0.1, 0.2, 0.4]), det("person", [0.12, 0.1, 0.2, 0.4])]
    {_t, [b2, a2]} = Tracker.track(t, moved)

    assert a2.object_id == a.object_id
    assert b2.object_id == b.object_id
  end

  test "objects unseen for several batches are dropped" do
    {t, [a]} = Tracker.track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4])])

    t = Enum.reduce(1..6, t, fn _, t -> elem(Tracker.track(t, []), 0) end)
    {_t, [b]} = Tracker.track(t, [det("person", [0.1, 0.1, 0.2, 0.4])])

    refute a.object_id == b.object_id
  end
end
