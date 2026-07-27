defmodule Cairn.TrackerTest do
  use ExUnit.Case, async: true

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
      max_unseen_ms: Keyword.get(opts, :max_unseen_ms, @max_unseen)
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

      assert [{:ended, %Track{object_id: id, end_reason: :unseen}}] = ended
      assert id == a.object_id

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
      assert ids(events, :ended) == []
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

      {_t, [c], events} = track(t, [det("person", [0.1, 0.1, 0.2, 0.4])], media_ms: 0)

      assert ids(events, :ended) == []
      assert c.object_id == a.object_id
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

  describe "end_all/2" do
    test "ends every live track with the given reason and returns a fresh tracker" do
      dets = [det("person", [0.1, 0.1, 0.2, 0.4]), det("cat", [0.7, 0.1, 0.2, 0.4])]
      {t, tagged, _} = track(Tracker.new(), dets)

      {fresh, events} = Tracker.end_all(t, :stream_reset)

      assert Enum.sort(ids(events, :ended)) == Enum.sort(Enum.map(tagged, & &1.object_id))
      assert Enum.all?(events, fn {:ended, track} -> track.end_reason == :stream_reset end)
      assert Tracker.live_tracks(fresh) == []

      # nothing matches across the cut
      {_t, [a], _} = track(fresh, [det("person", [0.1, 0.1, 0.2, 0.4])], media_ms: 200)
      refute a.object_id in Enum.map(tagged, & &1.object_id)
    end
  end

  test "live_tracks/1 summarizes what is currently tracked" do
    {t, [a], _} = track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4])])

    assert [%Track{object_id: id, end_reason: nil}] = Tracker.live_tracks(t)
    assert id == a.object_id
  end
end
