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

  test "an identity adopted across a cut names the session it is seen under" do
    box = [0.1, 0.1, 0.05, 0.1]

    {state, _tagged, _events} =
      SparseTrack.track(SparseTrack.new(), [object(box)], context(0, 100))

    {state, _events, _report} = SparseTrack.suspend(state, 8, 1_000)

    # Same object, new epoch: the adopting batch takes the identity back, and
    # the one after it is where the resumed identity is published again.
    epoch_two = %{context(2_000, 2_100) | epoch: 9}
    {state, _tagged, _events} = SparseTrack.track(state, [object(box)], epoch_two)

    {_state, _tagged, events} =
      SparseTrack.track(state, [object(box)], %{epoch_two | at_ms: 2_100, observed_at: 2_200})

    # A summary still naming the dead session reads as stale, and the identity
    # did not restart — so the epoch moves and `started_at` does not.
    assert [{:updated, %Track{epoch: 9, started_at: 100}}, {:adopted, %Track{epoch: 9}}] = events
  end

  describe "the live cap" do
    test "the host's cap stands in for a caller that names none" do
      cap = Cairn.Config.default_max_live_tracks()

      # One box over the cap, all minted on one frame: the tree's own default
      # is no cap at all, so anything but the host's leaves every one of them.
      objects = for i <- 0..cap, do: object([i / 4000, 0.1, 0.01, 0.02])
      {state, _tagged, events} = SparseTrack.track(SparseTrack.new(), objects, context(0))

      assert [{:ended, %Track{object_id: 1, end_reason: :evicted}}] =
               Enum.filter(events, &match?({:ended, _}, &1))

      assert length(SparseTrack.checkpoint_tracks(state)) == cap
    end

    test "a cap the caller names is the one that applies" do
      state = SparseTrack.new(max_live: 1)
      objects = [object([0.1, 0.1, 0.05, 0.1]), object([0.5, 0.1, 0.05, 0.1])]

      {state, _tagged, events} = SparseTrack.track(state, objects, context(0, 100))

      assert [{:ended, %Track{object_id: 1, end_reason: :evicted, camera_id: "cam-1"}}] =
               Enum.filter(events, &match?({:ended, _}, &1))

      assert [%Track{object_id: 2}] = SparseTrack.checkpoint_tracks(state)
    end
  end

  describe "the runtime evidence floor" do
    # What `Cairn.Pipeline.ObservationStamper` resolves into the context, with
    # the runtime override already folded in.
    defp floored(at_ms, floors), do: Map.put(context(at_ms), :min_score, floors)

    test "a raised floor stops a below-floor detection minting" do
      {_state, tagged, events} =
        SparseTrack.track(
          SparseTrack.new(),
          [object([0.1, 0.1, 0.05, 0.1], 0.7)],
          floored(0, %{"default" => 0.8})
        )

      assert tagged == []
      assert events == []
    end

    test "a raised floor stops a below-floor detection updating a live track" do
      box = [0.1, 0.1, 0.05, 0.1]
      state = SparseTrack.new()

      {state, _tagged, _events} = SparseTrack.track(state, [object(box, 0.9)], floored(0, nil))

      # Below the raised floor: the cairn core would have offered it to
      # ByteTrack's second stage, which is exactly what a raised floor says not
      # to do.
      {_state, tagged, events} =
        SparseTrack.track(state, [object(box, 0.7)], floored(1, %{"default" => 0.8}))

      assert tagged == []
      assert events == []
    end

    test "the floor is per label, and the same one Cairn.Tracker reads" do
      floors = %{"default" => 0.8, "car" => 0.2}
      car = %{bbox: [0.5, 0.1, 0.05, 0.1], score: 0.7, label: "car"}

      {_state, tagged, _events} =
        SparseTrack.track(
          SparseTrack.new(),
          [object([0.1, 0.1, 0.05, 0.1], 0.7), car],
          floored(0, floors)
        )

      assert [%{label: "car"}] = tagged
    end

    test "no floor in the context leaves the batch as the core would have seen it" do
      objects = [object([0.1, 0.1, 0.05, 0.1], 0.7)]

      {_state, floorless, _events} = SparseTrack.track(SparseTrack.new(), objects, context(0))
      {_state, unset, _events} = SparseTrack.track(SparseTrack.new(), objects, floored(0, nil))

      assert [%{object_id: 1}] = floorless
      assert floorless == unset
    end
  end

  test "checkpoint_tracks returns Cairn.Track structs" do
    {state, _tagged, _events} =
      SparseTrack.track(SparseTrack.new(), [object([0.1, 0.1, 0.05, 0.1])], context(0))

    assert [%Track{camera_id: "cam-1", object_id: _}] = SparseTrack.checkpoint_tracks(state)
  end
end
