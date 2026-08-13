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

  defp drop_ids(tagged), do: Enum.map(tagged, &Map.delete(&1, :object_id))

  # Crockford base32, 26 characters: what `Cairn.ULID` mints and what every
  # consumer of an `object_id` is typed for.
  defp ulid?(id), do: is_binary(id) and id =~ ~r/^[0-9A-HJKMNP-TV-Z]{26}$/

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
    # third call (nothing detected twice running) expires the track — and the
    # fourth is when it leaves the core for good, which is what the final is
    # dated by (`Membrane.MOTTracker.SparseTrack`'s faithfulness notes).
    state = SparseTrack.new(track_buffer: 1)
    box = [0.1, 0.1, 0.05, 0.1]

    {state, _tagged, _events} = SparseTrack.track(state, [object(box)], context(0))
    {state, _tagged, marked_lost} = SparseTrack.track(state, [], context(1))
    assert marked_lost == []

    {state, _tagged, expiring} = SparseTrack.track(state, [], context(2))
    assert expiring == []

    {_state, _tagged, events} = SparseTrack.track(state, [], context(3))

    assert [{:ended, %Track{end_reason: :unseen}}] = events
  end

  test "every summary dates the track by its last real detection" do
    # A `%Cairn.Track{}` is self-contained wherever it lands (the DB row, the
    # PubSub message, the checkpoint), so the field is on every kind and not
    # only on the ones a live consumer happens to fold.
    box = [0.1, 0.1, 0.05, 0.1]

    {state, _tagged, [{:started, started}]} =
      SparseTrack.track(SparseTrack.new(track_buffer: 1), [object(box)], context(0, 100))

    assert started.last_detected_at == 100

    {state, _tagged, [{:updated, updated}]} =
      SparseTrack.track(state, [object(box)], context(1, 200))

    assert updated.last_detected_at == 200

    # Nothing matches from here on, so the last detection stands still while
    # the track ages out — on the snapshot and on the final alike.
    {state, _tagged, []} = SparseTrack.track(state, [], context(2, 300))
    assert [%Track{last_detected_at: 200}] = SparseTrack.checkpoint_tracks(state)

    {state, _tagged, []} = SparseTrack.track(state, [], context(3, 400))
    {_state, _tagged, [{:ended, ended}]} = SparseTrack.track(state, [], context(4, 500))

    assert ended.last_detected_at == 200
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

    {state, [%{object_id: oid}], _events} =
      SparseTrack.track(SparseTrack.new(), [object(box)], context(0, 100))

    {state, _events, _report} = SparseTrack.suspend(state, 8, 1_000)

    # Same object, new epoch: the adopting batch takes the identity back, and
    # the one after it is where the resumed identity is published again.
    epoch_two = %{context(2_000, 2_100) | epoch: 9}
    {state, _tagged, _events} = SparseTrack.track(state, [object(box)], epoch_two)

    {_state, _tagged, events} =
      SparseTrack.track(state, [object(box)], %{epoch_two | at_ms: 2_100, observed_at: 2_200})

    # A summary still naming the dead session reads as stale, and the identity
    # did not restart — so the epoch moves while `started_at` and the minted id
    # do not. The id is the reason the adoption is worth anything: a consumer
    # that gets a new one has been told the object is a different object.
    assert [
             {:updated, %Track{epoch: 9, started_at: 100, object_id: ^oid}},
             {:adopted, %Track{epoch: 9, object_id: ^oid}}
           ] = events
  end

  describe "identities" do
    test "every summary kind names the track with a minted ULID, never the core's counter" do
      box = [0.1, 0.1, 0.05, 0.1]

      {state, [tagged], [{:started, started}]} =
        SparseTrack.track(SparseTrack.new(track_buffer: 1), [object(box)], context(0, 100))

      oid = tagged.object_id
      assert ulid?(oid)
      assert started.object_id == oid

      {state, [%{object_id: ^oid}], [{:updated, %Track{object_id: ^oid}}]} =
        SparseTrack.track(state, [object(box)], context(1, 200))

      assert [%Track{object_id: ^oid}] = SparseTrack.checkpoint_tracks(state)

      # Nothing matches from here on, so the identity ages out — and the final
      # is owed to the same name every earlier summary carried.
      {state, [], []} = SparseTrack.track(state, [], context(2, 300))
      {state, [], []} = SparseTrack.track(state, [], context(3, 400))
      {state, [], [{:ended, %Track{object_id: ^oid}}]} = SparseTrack.track(state, [], context(4))

      # …and the mapping ends with the identity, so a camera that runs for a
      # week does not carry a book entry per track it ever saw.
      assert state.book == %{}
    end

    test "two cameras tracking the same box mint identities that cannot collide" do
      box = [0.1, 0.1, 0.05, 0.1]
      cam_two = %{context(0) | camera_id: "cam-2"}

      {_state, [one], _events} = SparseTrack.track(SparseTrack.new(), [object(box)], context(0))
      {_state, [two], _events} = SparseTrack.track(SparseTrack.new(), [object(box)], cam_two)

      # Both are the inner core's id 1, which is exactly the collision the mint
      # exists to prevent — in the track index they are two rows, not one.
      refute one.object_id == two.object_id
    end

    test "a suspended identity's final still names it" do
      box = [0.1, 0.1, 0.05, 0.1]

      {state, [tagged], _events} =
        SparseTrack.track(SparseTrack.new(), [object(box)], context(0, 100))

      {state, [], _report} = SparseTrack.suspend(state, 8, 1_000)
      assert map_size(state.book) == 1

      {state, [{:ended, %Track{object_id: object_id}}]} =
        SparseTrack.expire_suspended(state, 1_000 + SparseTrack.adoption_window_ms() + 1)

      assert object_id == tagged.object_id
      assert state.book == %{}
    end

    test "end_all forgets every mapping it ends" do
      {state, [_tagged], _events} =
        SparseTrack.track(SparseTrack.new(), [object([0.1, 0.1, 0.05, 0.1])], context(0, 100))

      {state, [{:ended, %Track{end_reason: :detection_disabled}}]} =
        SparseTrack.end_all(state, :detection_disabled)

      assert state.book == %{}
    end
  end

  describe "the live cap" do
    test "the host's cap stands in for a caller that names none" do
      cap = Cairn.Config.default_max_live_tracks()

      # One box over the cap, all minted on one frame: the tree's own default
      # is no cap at all, so anything but the host's leaves every one of them.
      objects = for i <- 0..cap, do: object([i / 4000, 0.1, 0.01, 0.02])
      {state, tagged, events} = SparseTrack.track(SparseTrack.new(), objects, context(0))

      assert [{:ended, %Track{object_id: evicted, end_reason: :evicted}}] =
               Enum.filter(events, &match?({:ended, _}, &1))

      # The eviction is of a track this same frame also tagged, so the two name
      # it identically or a consumer folding the pair ends a track it never
      # started.
      assert evicted in Enum.map(tagged, & &1.object_id)

      assert length(SparseTrack.checkpoint_tracks(state)) == cap
    end

    test "a cap the caller names is the one that applies" do
      state = SparseTrack.new(max_live: 1)
      objects = [object([0.1, 0.1, 0.05, 0.1]), object([0.5, 0.1, 0.05, 0.1])]

      {state, _tagged, events} = SparseTrack.track(state, objects, context(0, 100))

      assert [{:ended, %Track{object_id: evicted, end_reason: :evicted, camera_id: "cam-1"}}] =
               Enum.filter(events, &match?({:ended, _}, &1))

      assert [%Track{object_id: kept}] = SparseTrack.checkpoint_tracks(state)
      refute kept == evicted
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

      # The identities are two independent mints; everything else about the
      # batch is what has to match.
      assert [%{label: "person"}] = floorless
      assert drop_ids(floorless) == drop_ids(unset)
    end
  end

  test "checkpoint_tracks returns Cairn.Track structs" do
    {state, _tagged, _events} =
      SparseTrack.track(SparseTrack.new(), [object([0.1, 0.1, 0.05, 0.1])], context(0))

    assert [%Track{camera_id: "cam-1", object_id: _}] = SparseTrack.checkpoint_tracks(state)
  end
end
