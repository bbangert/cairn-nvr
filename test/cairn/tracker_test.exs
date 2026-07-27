defmodule Cairn.TrackerTest do
  use ExUnit.Case, async: true

  alias Cairn.PluginProtocol
  alias Cairn.Tracker

  defp det(label, bbox, score \\ 0.9), do: %{label: label, bbox: bbox, score: score}

  # `iou/2` only matches `[x, y, w, h]`, and a stored object's bbox comes
  # straight from the detection that created it — so a bbox of any other arity
  # reaching `track/2` crashes the (singleton) aggregator on the next
  # same-label batch. Everything the ports feed it passes validate_det/1
  # first; this pins that the validator can only ever emit 4-number bboxes.
  test "every det the plugin protocol admits has a 4-number bbox track/2 can match" do
    arities = [
      [],
      [0.1],
      [0.1, 0.1],
      [0.1, 0.1, 0.2],
      [0.1, 0.1, 0.2, 0.2],
      [0.1, 0.1, 0.2, 0.2, 0.2]
    ]

    values = [0, 1, 0.5, -0.1, 1.5, "0.5", nil]

    bboxes =
      arities ++
        for(v <- values, do: [v, 0.1, 0.2, 0.2]) ++ for(v <- values, do: [0.1, 0.1, v, 0.2])

    valid =
      for bbox <- bboxes,
          {:ok, det} <- [
            PluginProtocol.validate_det(%{"label" => "person", "score" => 0.9, "bbox" => bbox})
          ],
          do: det

    # non-vacuity: the generator silently skips every :error, so a validator
    # that rejected everything would otherwise pass this test with no assertions
    assert length(valid) == 6

    for det <- valid do
      assert [a, b, c, d] = det.bbox
      assert Enum.all?([a, b, c, d], &is_number/1)

      # a stored object compared against a follow-up same-label batch is the
      # path that calls iou/2 — tracking against an empty tracker never does
      {tracker, [%{object_id: id}]} = Tracker.track(Tracker.new(), [det])
      assert {_t, [%{object_id: ^id}]} = Tracker.track(tracker, [det])
    end
  end

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
