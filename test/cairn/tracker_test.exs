defmodule Cairn.TrackerTest do
  use ExUnit.Case, async: true

  import Cairn.TrackAssertions
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Cairn.PluginProtocol
  alias Cairn.Track
  alias Cairn.Tracker

  @max_unseen 3_000

  defp det(label, bbox, opts \\ []) do
    %{
      label: label,
      bbox: bbox,
      score: Keyword.get(opts, :score, 0.9),
      track_id: Keyword.get(opts, :track_id),
      observation_kind: Keyword.get(opts, :kind, "detected")
    }
  end

  defp ctx(opts) do
    %{
      camera_id: Keyword.get(opts, :camera_id, "cam_a"),
      epoch: Keyword.get(opts, :epoch, "epoch_one"),
      plugin_instance: Keyword.get(opts, :plugin_instance, "cam_a"),
      media_ms: Keyword.get(opts, :media_ms, 0),
      observed_at: Keyword.get(opts, :observed_at, ~U[2026-07-26 12:00:00Z]),
      tracking: Keyword.get(opts, :tracking, false),
      ended_tracks: Keyword.get(opts, :ended_tracks, []),
      max_unseen_ms: Keyword.get(opts, :max_unseen_ms, @max_unseen),
      max_live_tracks: Keyword.get(opts, :max_live_tracks, 128),
      now_ms: Keyword.get(opts, :now_ms, 0)
    }
  end

  defp track(tracker, objects, opts \\ []), do: Tracker.track(tracker, objects, ctx(opts))

  defp ids(events, kind) do
    for {^kind, %Track{object_id: id}} <- events, do: id
  end

  defp plugin_ctx(opts), do: Keyword.merge([tracking: true, plugin_instance: "grp"], opts)

  # `iou/2` only matches `[x, y, w, h]`, and a stored object's bbox comes
  # straight from the detection that created it — so a bbox of any other arity
  # reaching `track/3` crashes the (singleton) aggregator on the next
  # same-label batch. Everything the ports feed it passes validate_det/1
  # first; this pins that the validator can only ever emit 4-number bboxes.
  test "every det the plugin protocol admits has a 4-number bbox track/3 can match" do
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
      {tracker, [%{object_id: id}], _started} = track(Tracker.new(), [det])
      assert {_t, [%{object_id: ^id}], _events} = track(tracker, [det])
    end
  end

  test "iou" do
    assert Tracker.iou([0, 0, 2, 2], [0, 0, 2, 2]) == 1.0
    assert Tracker.iou([0, 0, 2, 2], [2, 2, 2, 2]) == 0.0
    assert Tracker.iou([0, 0, 2, 2], [1, 1, 2, 2]) == 1 / 7
  end

  describe "host mode" do
    test "object ids are ULID strings, unique per object" do
      {_t, [a], [{:started, track}]} = track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4])])

      assert is_binary(a.object_id)
      assert String.length(a.object_id) == 26
      assert track.object_id == a.object_id
      assert track.source == :host
      assert track.plugin_track_id == nil
      assert track.camera_id == "cam_a"
      assert track.best_score == 0.9
      assert track.started_at == ~U[2026-07-26 12:00:00Z]
      refute track.stale_predicted
    end

    test "same object keeps its id across overlapping frames" do
      {t, [a], _} = track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4])])
      {_t, [b], events} = track(t, [det("person", [0.12, 0.1, 0.2, 0.4])], media_ms: 200)

      assert a.object_id == b.object_id
      assert ids(events, :started) == []
      assert ids(events, :updated) == [a.object_id]
    end

    test "non-overlapping detection of same label gets a new id" do
      {t, [a], _} = track(Tracker.new(), [det("person", [0.0, 0.0, 0.1, 0.1])])
      {_t, [b], events} = track(t, [det("person", [0.8, 0.8, 0.1, 0.1])], media_ms: 200)

      refute a.object_id == b.object_id
      assert ids(events, :started) == [b.object_id]
    end

    test "labels never match each other even when overlapping" do
      {t, [a], _} = track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4])])
      {_t, [b], _} = track(t, [det("cat", [0.1, 0.1, 0.2, 0.4])], media_ms: 200)

      refute a.object_id == b.object_id
    end

    test "two objects tracked independently in one batch" do
      dets = [det("person", [0.1, 0.1, 0.2, 0.4]), det("person", [0.7, 0.1, 0.2, 0.4])]
      {t, [a, b], _} = track(Tracker.new(), dets)
      assert a.object_id != b.object_id

      moved = [det("person", [0.72, 0.1, 0.2, 0.4]), det("person", [0.12, 0.1, 0.2, 0.4])]
      {_t, [b2, a2], _} = track(t, moved, media_ms: 200)

      assert a2.object_id == a.object_id
      assert b2.object_id == b.object_id
    end

    test "the best score over the track's life is kept" do
      {t, _, _} = track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4], score: 0.6)])

      {t, _, [{:updated, high}]} =
        track(t, [det("person", [0.1, 0.1, 0.2, 0.4], score: 0.95)], media_ms: 200)

      {_t, _, [{:updated, low}]} =
        track(t, [det("person", [0.1, 0.1, 0.2, 0.4], score: 0.7)], media_ms: 400)

      assert high.best_score == 0.95
      assert low.score == 0.7
      assert low.best_score == 0.95
    end
  end

  describe "media-time expiry" do
    # The batch-count rule this replaced expired after 5 missed batches: 5s at
    # 1 fps but 333ms at 15 fps. Media time makes both the same 3s.
    test "expires after max_unseen_ms of media time at 1 fps" do
      {t, [a], _} = track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4])])

      {t, [], []} = track(t, [], media_ms: 2_000)
      {t, [], []} = track(t, [], media_ms: 3_000)
      {t, [], ended} = track(t, [], media_ms: 3_100)

      assert [{:ended, %Track{object_id: id, end_reason: :unseen} = final}] = ended
      assert id == a.object_id
      assert_self_contained(final)

      {_t, [b], _} = track(t, [det("person", [0.1, 0.1, 0.2, 0.4])], media_ms: 3_200)
      refute b.object_id == a.object_id
    end

    test "survives the same number of missed batches at 15 fps" do
      {t, [a], _} = track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4])])

      # 30 frames at 15 fps is 2s of media time: still the same object
      t =
        Enum.reduce(1..30, t, fn n, t ->
          {t, [], []} = track(t, [], media_ms: n * 66.7)
          t
        end)

      {_t, [b], events} = track(t, [det("person", [0.1, 0.1, 0.2, 0.4])], media_ms: 2_100)

      assert b.object_id == a.object_id
      # positively, not as a refute: `ids/2` silently drops anything that is
      # not a `{kind, %Track{}}` pair, so `== []` alone would also pass on a
      # tracker that emitted garbage or renamed the tag.
      assert [{:updated, %Track{object_id: updated}}] = events
      assert updated == a.object_id
    end

    test "a predicted object keeps the track alive; only detections clear the stale flag" do
      {t, _, _} = track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4])])

      # predicted for longer than max_unseen: alive (last_seen moves) but the
      # last *detection* is old, so it is no longer evidence
      {t, [a], [{:updated, tracked}]} =
        track(t, [det("person", [0.1, 0.1, 0.2, 0.4], kind: "tracked")], media_ms: 4_000)

      assert a.stale_predicted
      assert tracked.stale_predicted

      {_t, [b], [{:updated, redetected}]} =
        track(t, [det("person", [0.1, 0.1, 0.2, 0.4])], media_ms: 4_100)

      assert b.object_id == a.object_id
      refute b.stale_predicted
      refute redetected.stale_predicted
    end

    test "a backwards media-time jump inside an epoch expires nothing" do
      dets = [det("person", [0.1, 0.1, 0.2, 0.4]), det("cat", [0.7, 0.1, 0.2, 0.4])]
      {t, [a, _b], _} = track(Tracker.new(), dets, media_ms: 900_000)

      {t, [c], events} = track(t, [det("person", [0.1, 0.1, 0.2, 0.4])], media_ms: 0)

      # the whole event list, so "no ended" cannot be satisfied by a tracker
      # that emitted nothing at all, and the cat's survival is checked rather
      # than inferred from the absence of a final
      assert [{:updated, %Track{object_id: updated}}] = events
      assert updated == a.object_id
      assert c.object_id == a.object_id
      assert length(Tracker.live_tracks(t)) == 2
    end
  end

  describe "plugin mode" do
    test "the same track id is the same ULID within an epoch, whatever the boxes do" do
      {t, [a], [{:started, _}]} =
        track(
          Tracker.new(),
          [det("person", [0.0, 0.0, 0.1, 0.1], track_id: "t1")],
          plugin_ctx([])
        )

      # no overlap at all: host IoU would have called this a new object
      {_t, [b], events} =
        track(
          t,
          [det("person", [0.9, 0.9, 0.05, 0.05], track_id: "t1")],
          plugin_ctx(media_ms: 200)
        )

      assert b.object_id == a.object_id
      assert ids(events, :updated) == [a.object_id]
      assert [{:updated, %Track{source: :plugin, plugin_track_id: "t1"}}] = events
    end

    test "the same track id in a different epoch is a different ULID" do
      {t, [a], _} =
        track(
          Tracker.new(),
          [det("person", [0.1, 0.1, 0.2, 0.4], track_id: "t1")],
          plugin_ctx([])
        )

      {_t, [b], _} =
        track(
          t,
          [det("person", [0.1, 0.1, 0.2, 0.4], track_id: "t1")],
          plugin_ctx(epoch: "epoch_two", media_ms: 200)
        )

      refute b.object_id == a.object_id
    end

    test "ended_tracks ends the track with a self-contained final summary" do
      {t, [a], _} =
        track(
          Tracker.new(),
          [det("person", [0.1, 0.1, 0.2, 0.4], track_id: "t1", score: 0.95)],
          plugin_ctx([])
        )

      {_t, [], [{:ended, final}]} =
        track(t, [], plugin_ctx(media_ms: 200, ended_tracks: ["t1"]))

      assert_self_contained(final)
      assert final.object_id == a.object_id
      assert final.end_reason == :plugin_ended
      assert final.camera_id == "cam_a"
      assert final.label == "person"
      assert final.best_score == 0.95
      assert final.source == :plugin
      assert final.plugin_track_id == "t1"
      assert final.started_at == ~U[2026-07-26 12:00:00Z]
      assert final.last_seen_at == ~U[2026-07-26 12:00:00Z]
    end

    test "reusing an ended track id is a contract violation: warn and mint a new ULID" do
      {t, [a], _} =
        track(
          Tracker.new(),
          [det("person", [0.1, 0.1, 0.2, 0.4], track_id: "t1")],
          plugin_ctx([])
        )

      {t, [], _} = track(t, [], plugin_ctx(media_ms: 200, ended_tracks: ["t1"]))

      {{t, [b], events}, log} =
        with_log(fn ->
          track(
            t,
            [det("person", [0.1, 0.1, 0.2, 0.4], track_id: "t1")],
            plugin_ctx(media_ms: 400)
          )
        end)

      assert log =~ "reused track id \"t1\" after ending it"
      refute b.object_id == a.object_id
      assert ids(events, :started) == [b.object_id]

      # and the new identity is stable from there on
      {_t, [c], _} =
        track(
          t,
          [det("person", [0.1, 0.1, 0.2, 0.4], track_id: "t1")],
          plugin_ctx(media_ms: 600)
        )

      assert c.object_id == b.object_id
    end

    test "track ids from a plugin without the capability are ignored" do
      objects = [det("person", [0.0, 0.0, 0.1, 0.1], track_id: "t1")]
      {t, [a], [{:started, track}]} = track(Tracker.new(), objects)

      assert track.source == :host
      assert track.plugin_track_id == nil

      # same id, no overlap, no capability: host IoU decides, so it is new
      {_t, [b], _} =
        track(t, [det("person", [0.9, 0.9, 0.05, 0.05], track_id: "t1")], media_ms: 200)

      refute b.object_id == a.object_id
    end

    test "plugin tracks expire on media time like any other" do
      {t, [a], _} =
        track(
          Tracker.new(),
          [det("person", [0.1, 0.1, 0.2, 0.4], track_id: "t1")],
          plugin_ctx([])
        )

      {t, [], ended} = track(t, [], plugin_ctx(media_ms: 3_100))
      assert [{:ended, %Track{end_reason: :unseen}}] = ended

      # the id mapping went with it: the same track id is a new object
      {_t, [b], _} =
        track(
          t,
          [det("person", [0.1, 0.1, 0.2, 0.4], track_id: "t1")],
          plugin_ctx(media_ms: 3_200)
        )

      refute b.object_id == a.object_id
    end
  end

  describe "bounded live set" do
    # `media_ms` is the plugin's own pts. A plugin that never advances it holds
    # the clock that expires its tracks, so the host clock has to be able to
    # retire one on its own.
    test "a frozen media clock cannot pin a track alive: the host clock expires it" do
      {t, [a], _} = track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4])], now_ms: 0)

      # same pts, 30s of host time later: well inside the backstop, still live
      {t, [_], events} = track(t, [det("person", [0.1, 0.1, 0.2, 0.4])], now_ms: 30_000)
      assert [{:updated, %Track{}}] = events
      assert [%Track{}] = Tracker.live_tracks(t)

      # 10 x max_unseen_ms of host time with media time standing still
      {t, [], ended} = track(t, [], now_ms: 60_001)

      assert [{:ended, %Track{object_id: id, end_reason: :unseen} = final}] = ended
      assert id == a.object_id
      assert_self_contained(final)
      assert Tracker.live_tracks(t) == []
    end

    test "at the live-track cap the least recently seen track is evicted with a final" do
      capped = fn opts -> plugin_ctx(Keyword.put(opts, :max_live_tracks, 2)) end

      {t, [a], _} =
        track(Tracker.new(), [det("person", [0.0, 0.0, 0.05, 0.05], track_id: "t1")], capped.([]))

      {t, [b], _} =
        track(
          t,
          [det("person", [0.5, 0.5, 0.05, 0.05], track_id: "t2")],
          capped.(media_ms: 100)
        )

      # only t2 is refreshed, so t1 is the least recently seen of the two
      {t, _, _} =
        track(
          t,
          [det("person", [0.5, 0.5, 0.05, 0.05], track_id: "t2")],
          capped.(media_ms: 200)
        )

      {{t, [c], events}, log} =
        with_log(fn ->
          track(
            t,
            [det("person", [0.9, 0.9, 0.05, 0.05], track_id: "t3")],
            capped.(media_ms: 300)
          )
        end)

      assert log =~ "live-track cap"

      assert [{:ended, %Track{end_reason: :evicted} = final}, {:started, %Track{}}] = events
      assert final.object_id == a.object_id
      assert_self_contained(final)

      # the cap holds, and it retired the right one
      assert Enum.map(Tracker.live_tracks(t), & &1.object_id) ==
               Enum.sort([b.object_id, c.object_id])
    end

    test "the ended set is bounded and evicts the oldest ids first" do
      # nothing is ever live here: `ended_tracks` remembers an id whether or
      # not it named a live track, which is the growth this bound exists for
      t =
        1..4_200
        |> Enum.map(&"t#{&1}")
        |> Enum.chunk_every(64)
        |> Enum.reduce(Tracker.new(), fn chunk, t ->
          {t, [], []} = track(t, [], plugin_ctx(ended_tracks: chunk))
          t
        end)

      # halved at 4_097 (to 2_048), then the remaining 103 ids appended
      assert map_size(t.ended) == 2_151

      # the newest id survived: reusing it is still caught as a violation
      {{_t, _, _}, log} =
        with_log(fn ->
          track(t, [det("person", [0.1, 0.1, 0.2, 0.4], track_id: "t4200")], plugin_ctx([]))
        end)

      assert log =~ "reused track id"

      # the oldest was evicted, so its reuse is (only) no longer reported —
      # the identity outcome is a fresh ULID either way
      {{_t, _, _}, log} =
        with_log(fn ->
          track(t, [det("person", [0.1, 0.1, 0.2, 0.4], track_id: "t1")], plugin_ctx([]))
        end)

      refute log =~ "reused track id"
    end
  end

  test "an exact IoU tie is broken deterministically, not by map order" do
    same = [0.1, 0.1, 0.2, 0.4]
    {t, [a, b], _} = track(Tracker.new(), [det("person", same), det("person", same)])
    refute a.object_id == b.object_id

    # both candidates overlap perfectly; only the total sort key separates them
    {_t, [c], _} = track(t, [det("person", same)], media_ms: 200)
    assert c.object_id == Enum.min([a.object_id, b.object_id])
  end

  test "a track id repeated inside one batch binds once; the duplicate is dropped" do
    objects = [
      det("person", [0.1, 0.1, 0.2, 0.4], track_id: "t1"),
      det("person", [0.7, 0.1, 0.2, 0.4], track_id: "t1")
    ]

    {{t, tagged, events}, log} = with_log(fn -> track(Tracker.new(), objects, plugin_ctx([])) end)

    assert log =~ ~s(track id "t1" twice in one batch)

    # the first occurrence wins: one identity, one object, one lifecycle event
    assert [%{bbox: [0.1, 0.1, 0.2, 0.4], object_id: id}] = tagged
    assert [{:started, %Track{object_id: ^id}}] = events
    assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)
  end

  describe "end_all/3" do
    test "ends every live track with the given reason and returns a fresh tracker" do
      dets = [det("person", [0.1, 0.1, 0.2, 0.4]), det("cat", [0.7, 0.1, 0.2, 0.4])]
      {t, tagged, _} = track(Tracker.new(), dets)

      {fresh, events} = Tracker.end_all(t, :stream_reset)

      assert Enum.sort(ids(events, :ended)) == Enum.sort(Enum.map(tagged, & &1.object_id))
      assert Enum.all?(events, fn {:ended, track} -> track.end_reason == :stream_reset end)
      for {:ended, track} <- events, do: assert_self_contained(track)
      assert Tracker.live_tracks(fresh) == []

      # nothing matches across the cut
      {_t, [a], _} = track(fresh, [det("person", [0.1, 0.1, 0.2, 0.4])], media_ms: 200)
      refute a.object_id in Enum.map(tagged, & &1.object_id)
    end

    test "keep_ended: true carries the ended plugin ids over the cut" do
      {t, [a], _} =
        track(
          Tracker.new(),
          [det("person", [0.1, 0.1, 0.2, 0.4], track_id: "t1")],
          plugin_ctx([])
        )

      {t, _, _} = track(t, [], plugin_ctx(media_ms: 200, ended_tracks: ["t1"]))

      # the cut keeps the epoch, so "t1" is still an id the plugin ended
      {kept, _} = Tracker.end_all(t, :detection_disabled, keep_ended: true)

      {{_t, [reused], _}, log} =
        with_log(fn ->
          track(kept, [det("person", [0.1, 0.1, 0.2, 0.4], track_id: "t1")], plugin_ctx([]))
        end)

      assert log =~ "reused track id \"t1\" after ending it"
      refute reused.object_id == a.object_id

      # the default drops it: correct only where the epoch changes too
      {dropped, _} = Tracker.end_all(t, :stream_reset)

      {_result, log} =
        with_log(fn ->
          track(dropped, [det("person", [0.1, 0.1, 0.2, 0.4], track_id: "t1")], plugin_ctx([]))
        end)

      refute log =~ "reused track id"
    end
  end

  test "live_tracks/1 summarizes what is currently tracked" do
    {t, [a], _} = track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4])])

    assert [%Track{object_id: id, end_reason: nil}] = Tracker.live_tracks(t)
    assert id == a.object_id
  end

  test "live_tracks/1 returns tracks in ULID order" do
    # More than 32 tracks on purpose: below that the tracker's `objects` map is
    # a flatmap whose iteration order happens to be sorted, so a smaller scene
    # would pass whether or not the sort is there.
    dets = for i <- 0..39, do: det("person", [i * 0.02, 0.1, 0.01, 0.4])
    {t, tagged, _} = track(Tracker.new(), dets)

    ids = Enum.map(Tracker.live_tracks(t), & &1.object_id)

    assert length(ids) == 40
    assert ids == Enum.sort(ids)
    assert ids == Enum.sort(Enum.map(tagged, & &1.object_id))
  end
end
