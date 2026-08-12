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

  test "identities are handed out in input order, and a replay assigns the same ones" do
    objects = [object([0, 0, 50, 100]), object([400, 0, 50, 100]), object([800, 0, 50, 100])]

    {_state, tagged, _events} = step(SparseTrack.new([]), objects)
    {_state, replayed, _events} = step(SparseTrack.new([]), objects)

    assert ids(tagged) == [1, 2, 3]
    assert tagged == replayed
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
