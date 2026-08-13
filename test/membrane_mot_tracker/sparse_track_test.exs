defmodule Membrane.MOTTracker.SparseTrackTest do
  use ExUnit.Case, async: true

  alias Membrane.MOTTracker.SparseTrack

  # Every box below is in pixels, as the core requires, and every score clears
  # `det_thresh` (0.65) unless a test is about a score that does not.
  defp object(bbox, score \\ 0.9), do: %{bbox: bbox, score: score, label: "person"}

  defp step(state, objects, at_ms \\ 0) do
    SparseTrack.track(state, objects, %{at_ms: at_ms})
  end

  defp ids(tagged), do: Enum.map(tagged, & &1.object_id)

  defp ended(events), do: Enum.filter(events, &match?({:ended, _}, &1))

  describe "the depth cascade" do
    # Three tracks share a bottom edge, so they are one sublevel however many
    # are asked for. Their detections do not: the heights differ enough to
    # spread the bottoms across three. With one level everything associates;
    # with three, the track side runs out of levels after the first and the
    # detections in the surplus two are set aside unmatched — which is the
    # reference's own rule and the reason a level count is a tuning knob.
    setup do
      seed = [
        object([0, 500, 100, 100]),
        object([200, 500, 100, 100]),
        object([400, 500, 100, 100])
      ]

      # Same corners, taller boxes: each still overlaps its own track, and the
      # bottom edges now sit at 600, 640 and 680.
      next = [
        object([0, 500, 100, 100]),
        object([200, 500, 100, 140]),
        object([400, 500, 100, 180])
      ]

      %{seed: seed, next: next}
    end

    test "one level associates every detection", %{seed: seed, next: next} do
      {state, first, _events} = step(SparseTrack.new(depth_levels: 1), seed)
      {_state, tagged, _events} = step(state, next)

      assert ids(first) == [1, 2, 3]
      assert ids(tagged) == [1, 2, 3]
    end

    test "three levels associate only the nearest sublevel", %{seed: seed, next: next} do
      {state, _first, _events} = step(SparseTrack.new(depth_levels: 3), seed)
      {_state, tagged, _events} = step(state, next)

      # The nearest sublevel is the largest bottom edge — the box at x=400,
      # whose bottom is 680. The other two tracks kept their identities but
      # found nothing to match, so they are lost rather than tagged.
      assert ids(tagged) == [3]
    end

    test "a sublevel's leftovers are offered to the next one" do
      # Two tracks and two detections spread over two sublevels, with the
      # detections swapped between the levels: the near detection belongs to
      # the far track. Nothing matches inside a level, and only the leftovers
      # carrying forward can pair them up at all.
      seed = [object([0, 100, 100, 100]), object([0, 800, 100, 100])]
      {state, _first, _events} = step(SparseTrack.new(depth_levels: 2), seed)

      {_state, tagged, _events} =
        step(state, [object([0, 100, 100, 100]), object([0, 800, 100, 100])])

      assert ids(tagged) == [1, 2]
    end
  end

  describe "the two association stages" do
    test "a low-score detection extends a track but never mints one" do
      alone = SparseTrack.new([])

      {_state, tagged, _events} = step(alone, [object([10, 10, 100, 200], 0.4)])
      assert tagged == []

      {state, _first, _events} = step(alone, [object([10, 10, 100, 200])])
      {_state, tagged, _events} = step(state, [object([12, 10, 100, 200], 0.4)])

      assert ids(tagged) == [1]
    end

    test "a detection at or below the low floor is not evidence at all" do
      {state, _first, _events} = step(SparseTrack.new([]), [object([10, 10, 100, 200])])
      {_state, tagged, _events} = step(state, [object([12, 10, 100, 200], 0.1)])

      assert tagged == []
    end

    test "the confident detection is associated first" do
      {state, _first, _events} = step(SparseTrack.new([]), [object([100, 100, 100, 200])])

      # Both overlap the track, and the unsure one overlaps it perfectly — its
      # score-weighted cost (0.600) beats the confident one's (0.611), so a
      # tracker that ranked all detections together would take it. The stages
      # mean it is never offered until the confident one has been matched, so
      # the track follows the box that moved.
      {_state, tagged, _events} =
        step(state, [object([140, 100, 100, 200], 0.9), object([100, 100, 100, 200], 0.4)])

      assert [%{object_id: 1, bbox: [x | _rest]}] = tagged
      assert x > 120
    end
  end

  describe "the lost-track buffer" do
    test "an identity survives a gap inside the buffer" do
      {state, _first, _events} =
        step(SparseTrack.new(track_buffer: 6), [object([10, 10, 100, 200])])

      state = Enum.reduce(1..4, state, fn _blank, state -> elem(step(state, []), 0) end)
      {_state, tagged, _events} = step(state, [object([10, 10, 100, 200])])

      assert ids(tagged) == [1]
    end

    test "an identity past the buffer is gone, and the next sighting is a new one" do
      {state, _first, _events} =
        step(SparseTrack.new(track_buffer: 6), [object([10, 10, 100, 200])])

      {state, ended} =
        Enum.reduce(1..10, {state, []}, fn _blank, {state, ended} ->
          {state, _tagged, events} = step(state, [])
          {state, ended ++ events}
        end)

      assert [{:ended, %{object_id: 1}}] = ended

      {state, _tagged, _events} = step(state, [object([10, 10, 100, 200])])
      {_state, tagged, _events} = step(state, [object([10, 10, 100, 200])])

      assert ids(tagged) == [2]
    end
  end

  # The expiry marks a track removed a frame before the subtraction drops it,
  # and the reference re-activates one that lingers there (the moduledoc's
  # first faithfulness note). The final is dated by the departure, so these
  # three say the same thing from three sides: nothing is ended while it can
  # still come back, and nothing comes back after it ended.
  describe "the frame an expired track lingers for" do
    setup do
      box = [10, 10, 100, 200]
      {state, _tagged, _events} = step(SparseTrack.new(track_buffer: 1), [object(box)])
      {state, _tagged, _events} = step(state, [])
      {state, _tagged, events} = step(state, [])

      # The expiry frame itself: marked removed, and silent about it.
      assert ended(events) == []

      %{state: state, box: box}
    end

    test "the snapshot still holds what the pool can still revive", %{state: state} do
      assert [%{object_id: 1}] = SparseTrack.checkpoint_tracks(state)
    end

    test "a revival is a plain update on an identity that never ended", %{
      state: state,
      box: box
    } do
      {state, tagged, events} = step(state, [object(box)])

      assert ids(tagged) == [1]
      assert [{:updated, %{object_id: 1}}] = events

      # And once it is lost again it leaves for good — an identity this core
      # removed once may not sit in the lost list a second time — with the one
      # final it has been owed all along.
      {state, _tagged, events} = step(state, [])

      assert [{:ended, %{object_id: 1}}] = ended(events)
      assert SparseTrack.checkpoint_tracks(state) == []
      assert {_state, [], []} = step(state, [])
    end

    test "an expiry nothing revives ends once, one frame later", %{state: state} do
      {state, _tagged, events} = step(state, [])

      assert [{:ended, %{object_id: 1}}] = ended(events)
      assert SparseTrack.checkpoint_tracks(state) == []

      {_state, _tagged, events} = step(state, [])
      assert ended(events) == []
    end
  end

  test "identities are handed out in input order, and a replay assigns the same ones" do
    objects = [object([0, 0, 50, 100]), object([400, 0, 50, 100]), object([800, 0, 50, 100])]

    {_state, tagged, _events} = step(SparseTrack.new([]), objects)
    {_state, replayed, _events} = step(SparseTrack.new([]), objects)

    assert ids(tagged) == [1, 2, 3]
    assert tagged == replayed
  end

  describe "the live cap (parity-exempt)" do
    test "no cap is the default, and it is what a parity run gets" do
      objects = for x <- 0..9, do: object([x * 150, 100, 100, 200])
      {state, tagged, events} = step(SparseTrack.new([]), objects)

      assert length(tagged) == 10
      assert ended(events) == []
      assert length(SparseTrack.checkpoint_tracks(state)) == 10
    end

    test "a lost track counts against the cap, and the least recent goes first" do
      near = object([0, 100, 100, 200])
      far = object([600, 100, 100, 200])

      # Two identities, then only the far one for a frame: the near one is lost
      # but still adoptable, so it is what the cap is measured against.
      {state, _tagged, _events} = step(SparseTrack.new(max_live: 2), [near, far], 0)
      {state, tagged, events} = step(state, [far], 1)
      assert ids(tagged) == [2]
      assert ended(events) == []

      # A third identity takes the frame to three, and the lost one is the
      # least recently seen of them.
      {state, _tagged, events} = step(state, [far, object([1200, 100, 100, 200])], 2)

      assert [{:ended, %{object_id: 1, reason: :evicted, at_ms: 2}}] = ended(events)
      assert Enum.map(SparseTrack.checkpoint_tracks(state), & &1.object_id) == [2]

      # Removed for good: the near box returns to an empty seat and mints a new
      # identity rather than resuming the evicted one.
      {state, _tagged, _events} = step(state, [near, far], 3)
      {_state, tagged, _events} = step(state, [near, far], 4)
      assert ids(tagged) == [2, 4]
    end

    test "ties are broken by id, not by iteration order" do
      objects = [object([0, 100, 100, 200]), object([600, 100, 100, 200])]

      # Both were seen on the same frame, so the frame counter cannot separate
      # them and the smaller id is the one that goes.
      {state, _tagged, events} = step(SparseTrack.new(max_live: 1), objects, 0)

      assert [{:ended, %{object_id: 1, reason: :evicted}}] = ended(events)
      assert Enum.map(SparseTrack.checkpoint_tracks(state), & &1.object_id) == [2]
    end

    test "an identity nothing was told about is evicted without a final" do
      far = object([600, 100, 100, 200])
      {state, _tagged, _events} = step(SparseTrack.new(max_live: 1), [far], 0)

      # Two mints on one frame, neither confirmed by a second sighting yet, and
      # a cap of one: the survivor is the newest, and the two evictions that
      # owe a final are exactly the one identity that had been published.
      {state, _tagged, events} =
        step(state, [far, object([1200, 100, 100, 200]), object([1500, 100, 100, 200])], 1)

      assert [{:ended, %{object_id: 1, reason: :evicted}}] = ended(events)
      assert SparseTrack.checkpoint_tracks(state) == []
    end
  end

  describe "suspension (parity-exempt)" do
    setup do
      {state, _tagged, _events} =
        step(
          SparseTrack.new([]),
          [object([100, 100, 100, 200]), object([600, 100, 100, 200])],
          1_000
        )

      %{state: state}
    end

    test "checkpoint_tracks round-trips the live tracks through a suspension", %{state: state} do
      live = SparseTrack.checkpoint_tracks(state)
      assert Enum.map(live, & &1.object_id) == [1, 2]

      {suspended, events, report} = SparseTrack.suspend(state, 8, 2_000)

      assert events == []
      assert report.suspended == 2
      assert report.ended == 0

      # Same identities, same boxes: a suspension moves a track aside, it does
      # not summarize it differently.
      assert Enum.map(SparseTrack.checkpoint_tracks(suspended), &{&1.object_id, &1.bbox}) ==
               Enum.map(live, &{&1.object_id, &1.bbox})
    end

    test "an overlapping detection inside the window takes its identity back", %{state: state} do
      {state, _events, _report} = SparseTrack.suspend(state, 8, 2_000)
      {state, _tagged, _events} = step(state, [object([110, 100, 100, 200])], 3_000)
      {_state, tagged, _events} = step(state, [object([110, 100, 100, 200])], 3_100)

      assert ids(tagged) == [1]
    end

    test "an adopted identity resumes rather than starting over", %{state: state} do
      {state, _events, _report} = SparseTrack.suspend(state, 8, 2_000)

      # The adopting frame publishes nothing: one box across a boundary
      # nothing observed corroborates no more than the first sighting of any
      # other minted track does.
      {state, tagged, events} = step(state, [object([110, 100, 100, 200])], 3_000)
      assert tagged == []
      assert events == []

      {_state, tagged, events} = step(state, [object([110, 100, 100, 200])], 3_100)

      assert ids(tagged) == [1]
      assert [{:updated, %{object_id: 1}}, {:adopted, %{object_id: 1}}] = events
    end

    test "an adopted identity that vanishes again is ended exactly once", %{state: state} do
      {state, _events, _report} = SparseTrack.suspend(state, 8, 2_000)
      {state, _tagged, _events} = step(state, [object([110, 100, 100, 200])], 3_000)

      # The confirmation never comes. The identity was published before the
      # cut, so it is owed the final an ordinary discarded mint is not.
      {state, _tagged, events} = step(state, [], 3_100)
      assert [{:ended, %{object_id: 1}}] = events

      {state, _tagged, later} = step(state, [], 3_200)
      assert later == []

      # …and the tracker no longer counts it among what it owes.
      assert Enum.map(SparseTrack.checkpoint_tracks(state), & &1.object_id) == [2]
    end

    test "a lapsed suspension is settled by the next batch, with no timer", %{state: state} do
      {state, _events, _report} = SparseTrack.suspend(state, 8, 2_000)

      # No `expire_suspended/2` call and no element timer: the batch that
      # arrives after the window closed is what closes it.
      {state, _tagged, events} =
        step(state, [], 2_000 + SparseTrack.adoption_window_ms() + 1)

      assert [{:ended, %{object_id: 1}}, {:ended, %{object_id: 2}}] = events
      assert SparseTrack.checkpoint_tracks(state) == []
    end

    test "the cap is over every suspension, not over each cut's arrivals", %{state: state} do
      {state, events, report} = SparseTrack.suspend(state, 2, 2_000)
      assert events == []
      assert report.suspended == 2

      # A new epoch mints and confirms two more identities, so the second cut
      # has four candidates for two slots.
      next = [object([1000, 100, 100, 200]), object([1400, 100, 100, 200])]
      {state, _tagged, _events} = step(state, next, 3_000)
      {state, _tagged, _events} = step(state, next, 3_100)

      {state, events, report} = SparseTrack.suspend(state, 2, 4_000)

      # The newest survive; the ghosts of the reset before last do not, and
      # they leave with the finals they are owed.
      assert report == %{suspended: 2, ended: 2, at: 3_100}
      assert [{:ended, %{object_id: 1}}, {:ended, %{object_id: 2}}] = events
      assert Enum.map(SparseTrack.checkpoint_tracks(state), & &1.object_id) == [3, 4]
    end

    test "the window running out ends what nothing adopted", %{state: state} do
      {state, _events, _report} = SparseTrack.suspend(state, 8, 2_000)

      {state, expired} =
        SparseTrack.expire_suspended(state, 2_000 + SparseTrack.adoption_window_ms() + 1)

      assert [{:ended, %{object_id: 1}}, {:ended, %{object_id: 2}}] = expired
      assert SparseTrack.checkpoint_tracks(state) == []
    end

    test "the cap ends what it cannot keep", %{state: state} do
      {state, events, report} = SparseTrack.suspend(state, 1, 2_000)

      assert report == %{suspended: 1, ended: 1, at: 1_000}
      assert [{:ended, %{object_id: 2}}] = events
      assert Enum.map(SparseTrack.checkpoint_tracks(state), & &1.object_id) == [1]
    end

    test "end_all leaves nothing owed", %{state: state} do
      {state, ended} = SparseTrack.end_all(state, :camera_stopped)

      assert [{:ended, %{object_id: 1, reason: :camera_stopped}}, {:ended, %{object_id: 2}}] =
               ended

      assert SparseTrack.checkpoint_tracks(state) == []
    end
  end
end
