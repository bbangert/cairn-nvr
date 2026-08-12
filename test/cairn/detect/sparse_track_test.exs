defmodule Cairn.Detect.SparseTrackTest do
  use ExUnit.Case, async: true

  alias Cairn.Detect.SparseTrack
  alias Cairn.Track

  # Every box is a normalized `[x, y, w, h]` fraction, well clear of the frame
  # edge and small next to the nominal 1920x1080 frame — so a pixel-scale
  # number leaking through is easy to tell apart from a fraction one.
  defp object(bbox, score \\ 0.9), do: %{bbox: bbox, score: score, label: "person"}

  defp context(at_ms, observed_at \\ nil),
    do: %{camera_id: "cam-1", epoch: 7, at_ms: at_ms, observed_at: observed_at || at_ms}

  test "a confirmed track's bbox round-trips through the nominal frame" do
    box = [0.1, 0.2, 0.05, 0.1]

    {_state, [tagged], [{:started, track}]} =
      SparseTrack.track(SparseTrack.new(), [object(box)], context(0))

    assert_in_delta(Enum.at(tagged.bbox, 0), Enum.at(box, 0), 1.0e-6)
    assert_in_delta(Enum.at(tagged.bbox, 1), Enum.at(box, 1), 1.0e-6)
    assert_in_delta(Enum.at(tagged.bbox, 2), Enum.at(box, 2), 1.0e-6)
    assert_in_delta(Enum.at(tagged.bbox, 3), Enum.at(box, 3), 1.0e-6)
    assert tagged.bbox == track.bbox

    # A pixel box at this scale (~192, ~216, ...) would fail this outright;
    # a normalized one stays well under 1.
    assert Enum.all?(tagged.bbox, &(&1 < 1))
  end

  test "a tagged entry carries the full adapter contract, honestly" do
    {_state, [tagged], _events} =
      SparseTrack.track(SparseTrack.new(), [object([0.1, 0.1, 0.05, 0.1])], context(0))

    assert %{
             object_id: _,
             label: "person",
             score: _,
             bbox: [_, _, _, _],
             stationary: false,
             stale_predicted: false,
             observation_kind: "detected"
           } = tagged
  end

  test "events carry Cairn.Track with context-derived fields and a running best_score" do
    box = [0.1, 0.2, 0.05, 0.1]

    {state, _tagged, [{:started, started}]} =
      SparseTrack.track(SparseTrack.new(), [object(box, 0.7)], context(0, 100))

    assert %Track{
             camera_id: "cam-1",
             epoch: 7,
             started_at: 100,
             last_seen_at: 100,
             best_score: 0.7,
             source: :host
           } = started

    # A higher-scoring sighting raises best_score; started_at survives it.
    {_state, _tagged, [{:updated, updated}]} =
      SparseTrack.track(state, [object(box, 0.95)], context(1, 200))

    assert %Track{started_at: 100, last_seen_at: 200, best_score: 0.95, score: 0.95} = updated
  end

  test "a natural expiry maps SparseTrack's :lost onto Cairn's :unseen" do
    # `track_buffer: 1` shrinks the lost-track buffer to one frame, so the
    # third call (nothing detected twice running) expires the track instead
    # of leaving it adoptable.
    state = SparseTrack.new(track_buffer: 1)
    box = [0.1, 0.1, 0.05, 0.1]

    {state, _tagged, _events} = SparseTrack.track(state, [object(box)], context(0))
    {state, _tagged, marked_lost} = SparseTrack.track(state, [], context(1))
    assert marked_lost == []

    {_state, _tagged, events} = SparseTrack.track(state, [], context(2))

    assert [{:ended, %Track{end_reason: :unseen}}] = events
  end

  test "a suspension reports its last sign of life in wall time" do
    # The host measures the outage gap as a `DateTime.diff/3` to this
    # (`Cairn.CameraTracker`'s `report_gap/2`), and the tree reports it on the
    # batch clock instead — so what comes back here has to be the observation's
    # own instant, not a number.
    seen_at = ~U[2026-08-12 10:00:00.000000Z]
    box = [0.1, 0.1, 0.05, 0.1]

    {state, _tagged, _events} =
      SparseTrack.track(SparseTrack.new(), [object(box)], context(0, seen_at))

    {state, _events, suspension} = SparseTrack.suspend(state, 8, 1)
    assert suspension.at == seen_at
    assert suspension.suspended == 1

    # …and what the window lapses on is a cairn final, not the tree's map.
    {_state, [{:ended, %Track{end_reason: :stream_reset} = final}]} =
      SparseTrack.expire_suspended(state, SparseTrack.adoption_window_ms() + 2)

    assert final.camera_id == "cam-1"
  end

  test "checkpoint_tracks returns Cairn.Track structs" do
    {state, _tagged, _events} =
      SparseTrack.track(SparseTrack.new(), [object([0.1, 0.1, 0.05, 0.1])], context(0))

    assert [%Track{camera_id: "cam-1", object_id: _}] = SparseTrack.checkpoint_tracks(state)
  end
end
