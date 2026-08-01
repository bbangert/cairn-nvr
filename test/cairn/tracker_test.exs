defmodule Cairn.TrackerTest do
  use ExUnit.Case, async: true

  import Cairn.TrackAssertions
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Cairn.PluginProtocol
  alias Cairn.Track
  alias Cairn.Tracker

  @max_unseen 3_000
  @stationary_after 10_000

  # The duplicate-suppression fixtures. Small and non-square on purpose: the
  # rule exists for boxes like these (a parked car at roughly 0.18 x 0.12
  # normalized), where a few pixels of detector drift cost far more IoU than
  # they do on the 0.4 x 0.4 boxes the rest of this file parks — and where a
  # box that only drifts in x, or only ever square, would hide an area factor
  # or a threshold comparison that lost an axis. Each is a different size and
  # aspect ratio, and the walker pair below drifts along the other axis.
  @parked_car [0.40, 0.50, 0.18, 0.12]
  # same box shifted a third of its width: IoU 0.5, between
  # @duplicate_suppression_iou (0.4) and @stationary_match_iou (0.7)
  @car_drift [0.46, 0.50, 0.18, 0.12]
  # wholly inside @parked_car and covering 45% of it, so IoU 0.45 — a detector
  # firing on part of the car rather than a box that moved
  @car_fragment [0.40, 0.50, 0.081, 0.12]
  # same box shifted half its width: IoU 1/3, below the suppression threshold
  @car_neighbour [0.49, 0.50, 0.18, 0.12]
  # the second box a detector without NMS emits for the *same* car, nudged on
  # both axes: IoU 0.783, which is the overlap the live failure's two anchors
  # had — far above @duplicate_suppression_iou and above @stationary_match_iou
  # too, so nothing about it looks like a second object
  @car_double [0.415, 0.505, 0.18, 0.12]
  # tall where the car boxes are wide, and displaced in y rather than x
  @walker [0.30, 0.20, 0.10, 0.30]
  # IoU 0.5 with @walker, the same overlap @car_drift has with @parked_car
  @walker_step [0.30, 0.30, 0.10, 0.30]

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
      stationary_after_ms: Keyword.get(opts, :stationary_after_ms, @stationary_after),
      now_ms: Keyword.get(opts, :now_ms, 0)
    }
  end

  defp track(tracker, objects, opts \\ []), do: Tracker.track(tracker, objects, ctx(opts))

  defp ids(events, kind) do
    for {^kind, %Track{object_id: id}} <- events, do: id
  end

  defp plugin_ctx(opts), do: Keyword.merge([tracking: true, plugin_instance: "grp"], opts)

  # Observation time derived from media time, so a `stationary_since` can be
  # checked against the step that set it.
  defp at(ms), do: DateTime.add(~U[2026-07-26 12:00:00Z], trunc(ms), :millisecond)

  # One plugin-tracked object over `{media_ms, bbox}` (or `{media_ms, bbox,
  # kind}`) steps, returning the last step's `track/3` result. Plugin mode on
  # purpose: identity is pinned by the track id, so what these tests exercise
  # is the stillness rule and not IoU matching.
  defp feed(tracker, steps) do
    Enum.reduce(steps, {tracker, [], []}, fn step, {tracker, _tagged, _events} ->
      {ms, bbox, kind} =
        case step do
          {ms, bbox} -> {ms, bbox, "detected"}
          {ms, bbox, kind} -> {ms, bbox, kind}
        end

      track(
        tracker,
        [det("person", bbox, track_id: "t1", kind: kind)],
        plugin_ctx(media_ms: ms, observed_at: at(ms))
      )
    end)
  end

  # One host-mode object of `label` detected every second at `box`, from media
  # time 0 through @stationary_after (10_000): stationary as of the last step,
  # with `last_seen_ms` 10_000, `last_seen_at` at(10_000) and
  # `last_seen_host_ms` 0 (the ctx default). Host
  # mode on purpose — what the grace tests are about is IoU identity, which a
  # plugin track id would pin regardless.
  defp parked(box, label \\ "person") do
    {tracker, id} =
      Enum.reduce(0..10, {Tracker.new(), nil}, fn n, {tracker, id} ->
        {tracker, [tagged], _events} =
          track(tracker, [det(label, box)], media_ms: n * 1_000, observed_at: at(n * 1_000))

        {tracker, id || tagged.object_id}
      end)

    assert [%Track{object_id: ^id, stationary: true}] = Tracker.live_tracks(tracker)
    {tracker, id}
  end

  # One host-mode object detected once per second of media time along `boxes`,
  # from media time 0. It has moved on every step, so it is not stationary and
  # its anchor is the last box in the list, anchored at `(length - 1) * 1_000`.
  defp moving(boxes, label \\ "person") do
    {tracker, id} =
      boxes
      |> Enum.with_index()
      |> Enum.reduce({Tracker.new(), nil}, fn {box, n}, {tracker, id} ->
        {tracker, [tagged], _events} =
          track(tracker, [det(label, box)], media_ms: n * 1_000, observed_at: at(n * 1_000))

        {tracker, id || tagged.object_id}
      end)

    assert [%Track{object_id: ^id, stationary: false}] = Tracker.live_tracks(tracker)
    {tracker, id}
  end

  # Every event of the whole run, for the tests that are about what never
  # happened.
  defp feed_all(tracker, steps) do
    Enum.reduce(steps, {tracker, []}, fn step, {tracker, seen} ->
      {tracker, _tagged, events} = feed(tracker, [step])
      {tracker, seen ++ events}
    end)
  end

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

  describe "stationary detection" do
    test "a box that holds still flips stationary only after stationary_after_ms" do
      box = [0.2, 0.2, 0.4, 0.4]

      {t, [tagged], events} = feed(Tracker.new(), for(n <- 0..9, do: {n * 1_000, box}))

      refute tagged.stationary
      assert [{:updated, %Track{stationary: false, stationary_since: nil}}] = events

      {t, [tagged], events} = feed(t, [{10_000, box}])

      assert tagged.stationary
      assert [{:updated, %Track{}}, {:became_stationary, %Track{} = flipped}] = events
      assert flipped.stationary
      assert flipped.stationary_since == at(10_000)
      assert flipped.stationary_ms == 0
      assert [%Track{stationary: true}] = Tracker.live_tracks(t)

      # the transition is an edge, not a level: staying still emits it once
      {_t, _tagged, events} = feed(t, [{11_000, box}])
      assert [{:updated, %Track{stationary: true, stationary_ms: 1_000}}] = events
    end

    test "a slow drift never reads stationary, however long it runs" do
      # each box overlaps the one before it well past @stationary_iou, so a
      # rule that compared consecutive boxes would call this motionless
      assert Tracker.iou([0.0, 0.0, 1.0, 1.0], [0.1, 0.0, 1.0, 1.0]) > 0.8

      steps = for n <- 0..20, do: {n * 1_000, [n * 0.1, 0.0, 1.0, 1.0]}
      {t, events} = feed_all(Tracker.new(), steps)

      # 20s of drift under a 10s threshold, and the anchor reset every time
      assert length(ids(events, :updated)) == 20
      assert for({:became_stationary, _} = e <- events, do: e) == []
      assert [%Track{stationary: false, stationary_ms: 0}] = Tracker.live_tracks(t)
    end

    test "detector jitter around a fixed point is absorbed by the median" do
      base = [0.0, 0.0, 1.0, 1.0]
      spike = [0.25, 0.0, 1.0, 1.0]

      # unsmoothed, a single spike box would reset the anchor on its own
      assert Tracker.iou(base, spike) < 0.8

      steps = for n <- 0..10, do: {n * 1_000, if(rem(n, 4) == 2, do: spike, else: base)}
      {_t, [tagged], events} = feed(Tracker.new(), steps)

      assert tagged.stationary
      assert [{:updated, _}, {:became_stationary, %Track{stationary_since: since}}] = events
      assert since == at(10_000)
    end

    test "the anchor is established by the first detection, not by a predicted first frame" do
      box = [0.0, 0.0, 1.0, 1.0]

      {t, events} =
        feed_all(Tracker.new(), [{0, box, "tracked"} | for(n <- 1..10, do: {n * 1_000, box})])

      # the anchor starts at the detection at 1_000, so 10_000 is still short
      assert for({:became_stationary, _} = e <- events, do: e) == []

      {_t, [tagged], events} = feed(t, [{11_000, box}])
      assert tagged.stationary
      assert [{:updated, _}, {:became_stationary, %Track{stationary_since: since}}] = events
      assert since == at(11_000)
    end

    test "predicted observations neither advance nor reset stillness" do
      box = [0.0, 0.0, 1.0, 1.0]
      elsewhere = [0.9, 0.0, 1.0, 1.0]

      {t, [tagged], _} = feed(Tracker.new(), for(n <- 0..10, do: {n * 1_000, box}))
      assert tagged.stationary

      # a predicted stretch, moved boxes included: nothing about stillness moves
      {t, [tagged], events} = feed(t, for(n <- 11..13, do: {n * 1_000, elsewhere, "tracked"}))

      assert tagged.stationary

      assert [{:updated, %Track{stationary: true, stationary_ms: 0} = still}] = events
      assert still.stationary_since == at(10_000)

      # the accrual is between detections, so the next one credits the gap
      {_t, _tagged, events} = feed(t, [{14_000, box}])
      assert [{:updated, %Track{stationary: true, stationary_ms: 4_000}}] = events
    end

    test "motion after a stationary stretch flips back and emits started_moving" do
      box = [0.0, 0.0, 1.0, 1.0]
      moved = [0.5, 0.0, 1.0, 1.0]

      {t, _, _} = feed(Tracker.new(), for(n <- 0..10, do: {n * 1_000, box}))

      # the median carries a real move once it holds the majority of the window
      {t, [held], _} = feed(t, [{11_000, moved}, {12_000, moved}])
      assert held.stationary

      {t, [tagged], events} = feed(t, [{13_000, moved}])

      refute tagged.stationary
      assert [{:updated, _}, {:started_moving, %Track{} = flipped}] = events
      refute flipped.stationary
      assert flipped.stationary_since == nil
      assert flipped.stationary_ms == 2_000
      assert [%Track{stationary: false}] = Tracker.live_tracks(t)
    end

    test "stationary_ms is a total: it survives a stationary -> moving -> stationary cycle" do
      box = [0.0, 0.0, 1.0, 1.0]
      moved = [0.5, 0.0, 1.0, 1.0]

      {t, _, _} =
        feed(Tracker.new(), for(n <- 0..12, do: {n * 1_000, if(n > 10, do: moved, else: box)}))

      {t, [tagged], events} = feed(t, [{13_000, moved}])
      refute tagged.stationary
      assert [_updated, {:started_moving, %Track{stationary_ms: 2_000}}] = events

      # the second stretch is measured from the move, and adds to the first
      {t, [tagged], events} = feed(t, for(n <- 14..23, do: {n * 1_000, moved}))
      assert tagged.stationary
      assert [_updated, {:became_stationary, %Track{stationary_ms: 2_000}}] = events

      {_t, _tagged, events} = feed(t, [{24_000, moved}, {25_000, moved}])
      assert [{:updated, %Track{stationary: true, stationary_ms: 4_000}}] = events
    end

    test "a backwards media-time jump while stationary accrues nothing" do
      box = [0.0, 0.0, 1.0, 1.0]

      {t, _, _} = feed(Tracker.new(), for(n <- 0..11, do: {n * 1_000, box}))
      {t, _, events} = feed(t, [{9_000, box}])

      assert [{:updated, %Track{stationary: true, stationary_ms: 1_000}}] = events
      assert [%Track{stationary_ms: 1_000}] = Tracker.live_tracks(t)
    end

    test "stillness is measured on every axis: y and height jitter, then a move in y" do
      base = [0.0, 0.0, 1.0, 1.0]
      lower = [0.0, 0.25, 1.0, 1.0]
      shorter = [0.0, 0.0, 1.0, 0.6]
      moved = [0.0, 0.5, 1.0, 1.0]

      # each spike alone is below @stationary_iou, on a different axis
      assert Tracker.iou(base, lower) < 0.8
      assert Tracker.iou(base, shorter) < 0.8

      steps =
        for n <- 0..10 do
          {n * 1_000,
           case rem(n, 4) do
             2 -> lower
             3 -> shorter
             _ -> base
           end}
        end

      {t, [tagged], events} = feed(Tracker.new(), steps)

      assert tagged.stationary
      assert [{:updated, _}, {:became_stationary, %Track{stationary_since: since}}] = events
      assert since == at(10_000)

      # a real move in y, which the median carries once it holds the window
      {t, events} = feed_all(t, for(n <- 11..13, do: {n * 1_000, moved}))

      assert [{:started_moving, %Track{stationary: false}}] =
               for({:started_moving, _} = e <- events, do: e)

      assert [%Track{stationary: false, stationary_ms: 1_000}] = Tracker.live_tracks(t)
    end

    test "a host-matched track goes stationary on the same stillness path" do
      box = [0.3, 0.3, 0.2, 0.2]
      jitter = [0.31, 0.3, 0.2, 0.2]

      # no track_id: identity is host IoU, and consecutive boxes overlap far
      # above @iou_threshold, so what this test can fail on is stillness
      assert Tracker.iou(box, jitter) > 0.9

      {t, events} =
        Enum.reduce(0..10, {Tracker.new(), []}, fn n, {tracker, seen} ->
          bbox = if rem(n, 2) == 0, do: box, else: jitter

          {tracker, [_tagged], events} =
            track(tracker, [det("person", bbox)], media_ms: n * 1_000, observed_at: at(n * 1_000))

          {tracker, seen ++ events}
        end)

      assert [id] = ids(events, :started)
      assert ids(events, :updated) == List.duplicate(id, 10)

      assert [{:became_stationary, %Track{} = flipped}] =
               for({:became_stationary, _} = e <- events, do: e)

      assert flipped.object_id == id
      assert flipped.source == :host
      assert flipped.plugin_track_id == nil
      assert flipped.stationary_since == at(10_000)
      assert [%Track{stationary: true}] = Tracker.live_tracks(t)
    end

    test "every tagged object carries the stationary flag, moving or not" do
      {_t, [tagged], _} = track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4])])

      assert Map.fetch!(tagged, :stationary) == false
    end
  end

  describe "stationary grace" do
    # @max_unseen is 3_000 and the tracker's @stationary_unseen_factor is 5, so
    # a stationary track's unseen bound is 15_000 of media time. `parked/1`
    # leaves `last_seen_ms` at 10_000, so the grace runs from 13_000 (past the
    # plain bound) to 25_000 (the extended one) of media time.
    test "a stationary track keeps its ULID across an occlusion past max_unseen_ms" do
      box = [0.0, 0.0, 0.4, 0.4]
      {t, id} = parked(box)

      # 4_000 unseen: a moving track would already be gone
      {t, [], events} = track(t, [], media_ms: 14_000)
      assert events == []

      {t, [tagged], events} =
        track(t, [det("person", box)], media_ms: 15_000, observed_at: at(15_000))

      assert tagged.object_id == id
      # the whole event list: no second `:started`, no `:ended` before it
      assert [{:updated, %Track{object_id: ^id}}] = events
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)
    end

    test "a passer-by in the grace does not take the parked identity" do
      box = [0.0, 0.0, 0.4, 0.4]
      passer = [0.2, 0.0, 0.4, 0.4]

      # non-vacuity: this box overlaps the parked one well above the base
      # @iou_threshold (0.1), so at the base threshold it would match and the
      # parked track would answer to it — only the grace threshold
      # (@stationary_match_iou, 0.7) refuses it
      assert_in_delta Tracker.iou(box, passer), 1 / 3, 0.001
      assert Tracker.iou(box, passer) > 0.1
      assert Tracker.iou(box, passer) < 0.7

      {t, id} = parked(box)

      # 4_000 unseen: inside the grace, so the parked track is a candidate and
      # this box is the one thing overlapping it
      {t, [tagged], events} =
        track(t, [det("person", passer)], media_ms: 14_000, observed_at: at(14_000))

      assert [{:started, %Track{object_id: passer_id}}] = events
      assert tagged.object_id == passer_id
      refute passer_id == id
      assert Enum.map(Tracker.live_tracks(t), & &1.object_id) == Enum.sort([id, passer_id])

      # and the identity was held, not merely withheld: the parked object is
      # still itself when it is detected again at 5_000 unseen
      {_t, [redetected], events} =
        track(t, [det("person", box)], media_ms: 15_000, observed_at: at(15_000))

      assert redetected.object_id == id
      assert ids(events, :started) == []
      assert ids(events, :updated) == [id]
    end

    test "a stationary track being seen normally still matches at the base threshold" do
      box = [0.0, 0.0, 0.4, 0.4]
      jitter = [0.2, 0.0, 0.4, 0.4]

      # between the base @iou_threshold (0.1) and @stationary_match_iou (0.7):
      # the strict threshold applied to a track that is still being seen would
      # reject this detection and mint a second track for the same object
      assert Tracker.iou(box, jitter) > 0.1
      assert Tracker.iou(box, jitter) < 0.7

      {t, id} = parked(box)

      # 1_000 unseen, well inside max_unseen_ms: not in grace
      {t, [tagged], events} =
        track(t, [det("person", jitter)], media_ms: 11_000, observed_at: at(11_000))

      assert tagged.object_id == id
      assert ids(events, :started) == []
      assert ids(events, :updated) == [id]
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)
    end

    # The grace is entered at strictly more than max_unseen_ms unseen, the same
    # edge expiry uses, so the two rules can never disagree about whether a
    # track is in grace.
    test "the strict threshold starts one millisecond past max_unseen_ms, not at it" do
      box = [0.0, 0.0, 0.4, 0.4]
      jitter = [0.2, 0.0, 0.4, 0.4]

      assert Tracker.iou(box, jitter) > 0.1
      assert Tracker.iou(box, jitter) < 0.7

      {t, id} = parked(box)

      # 10_000 + 3_000: unseen is exactly max_unseen_ms, so this is still
      # normal tracking and the base threshold matches
      {seen, [tagged], events} =
        track(t, [det("person", jitter)], media_ms: 13_000, observed_at: at(13_000))

      assert tagged.object_id == id
      assert [{:updated, %Track{object_id: ^id}}] = events
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(seen)

      # one millisecond later, from the same parked tracker: in grace, so the
      # same box is refused and gets an identity of its own
      {refused, [tagged], events} =
        track(t, [det("person", jitter)], media_ms: 13_001, observed_at: at(13_001))

      assert [{:started, %Track{object_id: other}}] = events
      assert tagged.object_id == other
      refute other == id
      assert Enum.map(Tracker.live_tracks(refused), & &1.object_id) == Enum.sort([id, other])
    end

    test "a box above the grace threshold does re-match, deep inside the grace" do
      box = [0.0, 0.0, 0.4, 0.4]
      offset = [0.05, 0.0, 0.4, 0.4]

      # 0.14 / 0.18: above @stationary_match_iou (0.7), and below 0.8 so a
      # threshold raised even a little would reject it — the accept side of the
      # same rule the passer-by test checks the reject side of
      assert Tracker.iou(box, offset) > 0.7
      assert Tracker.iou(box, offset) < 0.8

      {t, id} = parked(box)

      # 10_000 unseen: over three times max_unseen_ms, inside the 15_000 grace
      {t, [tagged], events} =
        track(t, [det("person", offset)], media_ms: 20_000, observed_at: at(20_000))

      assert tagged.object_id == id
      assert [{:updated, %Track{object_id: ^id}}] = events
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)
    end

    # The bound is on the track, not on how it got its identity. A plugin track
    # has no duplicate-identity risk to weigh — its id is pinned by `track_id`,
    # not by IoU — so nothing here has to hold it to the plain bound.
    test "a stationary plugin-mode track gets the same extended bound" do
      box = [0.0, 0.0, 0.4, 0.4]

      {t, [tagged], _} = feed(Tracker.new(), for(n <- 0..10, do: {n * 1_000, box}))
      assert tagged.stationary
      id = tagged.object_id

      # 10_000 unseen: past max_unseen_ms, inside 5 x 3_000
      {t, [], []} = track(t, [], plugin_ctx(media_ms: 20_000))
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)

      # past 10_000 + 15_000
      {t, [], ended} = track(t, [], plugin_ctx(media_ms: 25_100))
      assert [{:ended, %Track{object_id: ^id, end_reason: :unseen}}] = ended
      assert Tracker.live_tracks(t) == []
    end

    test "the grace has an end: extended bound for a stationary track, plain for a moving one" do
      box = [0.0, 0.0, 0.4, 0.4]
      {t, id} = parked(box)

      # a second track, elsewhere in the frame and never stationary, last seen
      # at the same 10_000 of media time
      {t, [mover], _} =
        track(t, [det("person", [0.6, 0.6, 0.2, 0.2])], media_ms: 10_000, observed_at: at(10_000))

      refute mover.object_id == id

      # 3_100 unseen: past max_unseen_ms (3_000) for the mover, and 3_100 of
      # the parked track's 15_000 (5 x 3_000)
      {t, [], events} = track(t, [], media_ms: 13_100)
      assert [{:ended, %Track{object_id: gone, end_reason: :unseen}}] = events
      assert gone == mover.object_id
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)

      # exactly at the extended bound (10_000 + 15_000): still live
      {t, [], []} = track(t, [], media_ms: 25_000)
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)

      {t, [], events} = track(t, [], media_ms: 25_100)
      assert [{:ended, %Track{object_id: ^id, end_reason: :unseen} = final}] = events
      assert_self_contained(final)
      assert Tracker.live_tracks(t) == []
    end

    # The media-time rule and the host-clock backstop are one boolean; a
    # backstop left on the plain bound would retire this track at 10 x 3_000 of
    # host time whatever its media-time grace said — and a frozen pts is
    # precisely when the media-time side never expires anything.
    test "the host-clock backstop scales with the grace too" do
      box = [0.0, 0.0, 0.4, 0.4]
      {t, id} = parked(box)

      # pts frozen at 10_000 from here on: only host time moves. 60_001 is past
      # the 10 x max_unseen_ms that expires a plain track (see "a frozen media
      # clock cannot pin a track alive")
      {t, [], []} = track(t, [], media_ms: 10_000, now_ms: 60_001)
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)

      # 10 x (5 x 3_000) of host time: the last moment it is alive
      {t, [], []} = track(t, [], media_ms: 10_000, now_ms: 150_000)
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)

      {t, [], ended} = track(t, [], media_ms: 10_000, now_ms: 150_001)
      assert [{:ended, %Track{object_id: ^id, end_reason: :unseen} = final}] = ended
      assert_self_contained(final)
      assert Tracker.live_tracks(t) == []
    end
  end

  describe "duplicate suppression" do
    # The tests about a track *refusing* a box park at 10_000 and then arrive at
    # 14_000: 4_000 unseen, inside the grace (past @max_unseen 3_000, well short
    # of 5 x 3_000), which is where a track is picky enough to refuse in the
    # first place. The ones about two boxes for one object need no grace at all
    # — the track takes the first box in the ordinary way — and arrive at
    # 11_000 instead.
    test "a drifted re-detection of a parked object is dropped, not minted" do
      # non-vacuity: refused by @stationary_match_iou (0.7), caught by
      # @duplicate_suppression_iou (0.4) — the band the whole rule is about
      assert_in_delta Tracker.iou(@parked_car, @car_drift), 0.5, 0.001

      {t, id} = parked(@parked_car, "car")

      {t, tagged, events} =
        track(t, [det("car", @car_drift, score: 0.95)],
          media_ms: 14_000,
          observed_at: at(14_000)
        )

      # the object is absent from the tagged list and nothing happened to any
      # track's lifecycle: no second `:started`, no `:updated`, no `:ended`
      assert tagged == []
      assert events == []

      # marked seen, and nothing more: the refused box is not in `bbox`, its
      # higher score is not in `best_score`, and the last *detection* is still
      # the parked one, so this is still not evidence
      assert [%Track{object_id: ^id, bbox: @parked_car, stationary: true} = still] =
               Tracker.live_tracks(t)

      assert still.last_seen_at == at(14_000)
      assert still.score == 0.9
      assert still.best_score == 0.9
      assert still.stale_predicted

      # and the media clock really moved: 25_100 is past the extended bound
      # measured from the parked track's last *match* (10_000 + 15_000) and
      # inside it measured from the refusal (14_000 + 15_000)
      {t, [], []} = track(t, [], media_ms: 25_100)
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)

      {t, [], ended} = track(t, [], media_ms: 29_100)
      assert [{:ended, %Track{object_id: ^id, end_reason: :unseen} = final}] = ended
      assert_self_contained(final)
      assert Tracker.live_tracks(t) == []
    end

    test "a fragment of a parked object's box is dropped, not minted" do
      assert_in_delta Tracker.iou(@parked_car, @car_fragment), 0.45, 0.001

      {t, id} = parked(@parked_car, "car")

      {t, tagged, events} =
        track(t, [det("car", @car_fragment)], media_ms: 14_000, observed_at: at(14_000))

      assert tagged == []
      assert events == []
      assert [%Track{object_id: ^id, bbox: @parked_car}] = Tracker.live_tracks(t)
    end

    test "a same-label box below the threshold is a new object: it mints, and marks nothing" do
      assert_in_delta Tracker.iou(@parked_car, @car_neighbour), 1 / 3, 0.001

      {t, id} = parked(@parked_car, "car")

      {t, [tagged], events} =
        track(t, [det("car", @car_neighbour)], media_ms: 14_000, observed_at: at(14_000))

      assert [{:started, %Track{object_id: other}}] = events
      refute other == id
      assert tagged.object_id == other

      assert Enum.map(Tracker.live_tracks(t), & &1.object_id) == Enum.sort([id, other])

      # and the parked track was not marked seen by a box that did not suppress
      assert [parked] = Enum.filter(Tracker.live_tracks(t), &(&1.object_id == id))
      assert parked.last_seen_at == at(10_000)
    end

    test "a different label overlapping a parked track still mints" do
      # a person standing in front of the parked car: far above the suppression
      # threshold, so only the same-label guard keeps it mintable
      assert Tracker.iou(@parked_car, @car_drift) >= 0.4

      {t, id} = parked(@parked_car, "car")

      {t, [tagged], events} =
        track(t, [det("person", @car_drift)], media_ms: 14_000, observed_at: at(14_000))

      assert [{:started, %Track{object_id: other, label: "person"}}] = events
      refute other == id
      assert tagged.object_id == other

      assert [parked] = Enum.filter(Tracker.live_tracks(t), &(&1.object_id == id))
      assert parked.last_seen_at == at(10_000)
      assert parked.label == "car"
    end

    # A detector without NMS emits two boxes for one object often enough to
    # matter. The first takes the track; the second is left over with nothing
    # left to match, and minting for it is how one parked car ends up with two
    # concurrent live tracks in the same epoch.
    test "two boxes for one object in one batch update one track and mint nothing" do
      # the overlap the two anchors of the observed failure had: nothing about
      # it looks like a second object — it is over @stationary_match_iou (0.7),
      # let alone @duplicate_suppression_iou
      assert_in_delta Tracker.iou(@parked_car, @car_double), 0.783, 0.001

      {t, id} = parked(@parked_car, "car")

      # one second after the track's last sighting, so no grace is involved:
      # the track takes the first box at the base @iou_threshold
      {t, tagged, events} =
        track(t, [det("car", @parked_car), det("car", @car_double, score: 0.95)],
          media_ms: 11_000,
          observed_at: at(11_000)
        )

      assert [%{object_id: ^id, bbox: @parked_car}] = tagged
      assert [{:updated, %Track{object_id: ^id}}] = events
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)
    end

    # The asymmetry in `seen/3`: presence is what a refused box is worth to a
    # track *nothing* observed. A track this batch matched was observed for
    # real, so the refusal must not add to it — and there is nothing left for it
    # to add.
    test "a second box over a matched track is refused, not merged into it" do
      {t, id} = parked(@parked_car, "car")

      {t, _tagged, _events} =
        track(t, [det("car", @parked_car, score: 0.6), det("car", @car_double, score: 0.95)],
          media_ms: 11_000,
          observed_at: at(11_000)
        )

      assert [%Track{object_id: ^id} = still] = Tracker.live_tracks(t)

      # every believed field is the *matched* detection's: the refused box's
      # geometry is not in `bbox` and its 0.95 is in neither `score` nor
      # `best_score` (0.9 is the best `parked/2` ever fed)
      assert still.bbox == @parked_car
      assert still.score == 0.6
      assert still.best_score == 0.9

      # and unlike a refusal against an unmatched track, which moves
      # `last_seen_at` and nothing else, this track's evidence clock moved too
      assert still.last_seen_at == at(11_000)
      assert still.last_detected_at == at(11_000)
      refute still.stale_predicted
    end

    # Pixel units and an exact ratio on purpose: 80/200 is 0.4 in binary
    # floating point with nothing to round, so this is the one place in the
    # suite where `>=` and `>` on the threshold give different answers.
    test "the suppression threshold includes its own boundary" do
      box = [640, 360, 20, 10]
      exactly = [640, 360, 8, 10]
      under = [640, 360, 7, 10]

      assert Tracker.iou(box, exactly) === 0.4
      assert Tracker.iou(box, under) === 0.35

      {t, id} = parked(box, "car")

      {_t, tagged, events} =
        track(t, [det("car", exactly)], media_ms: 14_000, observed_at: at(14_000))

      assert tagged == []
      assert events == []

      # the same tracker, one pixel of width less: below the threshold, so it
      # is a new object again
      {_t, [tagged], events} =
        track(t, [det("car", under)], media_ms: 14_000, observed_at: at(14_000))

      assert [{:started, %Track{object_id: other}}] = events
      refute other == id
      assert tagged.object_id == other
    end

    # The other half of the rule: a refusal is not permanent. Without the mark,
    # the parked track would sit in its grace refusing this box on every batch
    # until it expired, and the car would go untracked for the whole 15_000.
    test "a parked object whose detections flicker keeps one identity, not two or three" do
      {t, id} = parked(@parked_car, "car")

      # the observed failure: detections drop out for longer than max_unseen_ms
      # and come back a little off, at a score nothing would filter out
      {t, [], []} =
        track(t, [det("car", @car_drift, score: 0.7)],
          media_ms: 14_000,
          observed_at: at(14_000)
        )

      # from here it is detected every second at the drifted box. The refusal
      # took the track out of its grace, so the base threshold matches
      {t, seen_ids, started} =
        Enum.reduce(15_000..20_000//1_000, {t, [], []}, fn ms, {t, seen_ids, started} ->
          {t, [tagged], events} =
            track(t, [det("car", @car_drift, score: 0.7)], media_ms: ms, observed_at: at(ms))

          {t, [tagged.object_id | seen_ids], started ++ ids(events, :started)}
        end)

      assert length(seen_ids) == 6
      assert Enum.uniq(seen_ids) == [id]
      assert started == []
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)
    end

    # A refusal every 4_000 of media time is refused every time: each mark
    # leaves the next batch 4_000 unseen, back inside the grace.
    test "repeated refusals mint nothing and leave the stillness window untouched" do
      {t, id} = parked(@parked_car, "car")

      t =
        Enum.reduce([14_000, 18_000, 22_000, 26_000, 30_000], t, fn ms, t ->
          {t, [], []} = track(t, [det("car", @car_drift)], media_ms: ms, observed_at: at(ms))
          assert [%Track{object_id: ^id, bbox: @parked_car}] = Tracker.live_tracks(t)
          t
        end)

      # five refusals is a full @recent_boxes window. Adopting the drifted box
      # now still reads as *still*, because the median of the smoothing window
      # is the parked box — which is only true if none of the five refusals
      # went into `recent_boxes`, and if the anchor is still the parked box
      {_t, [tagged], events} =
        track(t, [det("car", @car_drift)], media_ms: 31_000, observed_at: at(31_000))

      assert tagged.object_id == id
      assert [{:updated, %Track{object_id: ^id, stationary: true, bbox: @car_drift}}] = events
    end

    # Suppression considers every live host track, matched or not, so the only
    # thing keeping a genuinely new object over a tracked one mintable is the
    # same-label guard in `duplicate_of/2`. This is the case that guard is for —
    # a person stepping in front of a tracked car — and the same geometry with
    # one label is the double-detection test above, which must not mint.
    test "a different-label object over a track this batch matched still mints" do
      assert_in_delta Tracker.iou(@walker, @walker_step), 0.5, 0.001

      {t, [a], _} = track(Tracker.new(), [det("car", @walker)])

      {t, [a2, b], events} =
        track(t, [det("car", @walker), det("person", @walker_step)],
          media_ms: 200,
          observed_at: at(200)
        )

      assert a2.object_id == a.object_id
      assert ids(events, :updated) == [a.object_id]

      assert [{:started, %Track{object_id: other, label: "person"}}] =
               for({:started, _} = e <- events, do: e)

      assert b.object_id == other
      refute other == a.object_id
      assert length(Tracker.live_tracks(t)) == 2
    end

    # Why suppression never has to ask whether a track is stationary: a track
    # matching at the base @iou_threshold takes a box like this outright, so it
    # is never both free and overlapped this much.
    test "a moving track adopts a drifted box outright rather than being marked seen" do
      {t, [a], _} = track(Tracker.new(), [det("person", @walker)])

      {t, [b], events} =
        track(t, [det("person", @walker_step)], media_ms: 200, observed_at: at(200))

      id = a.object_id
      assert b.object_id == id
      # adopted, not merely kept alive: the box moves and an `:updated` is
      # emitted, neither of which a suppression does
      assert [{:updated, %Track{object_id: ^id, bbox: @walker_step}}] = events

      assert [
               %Track{
                 object_id: ^id,
                 bbox: @walker_step,
                 last_seen_at: ~U[2026-07-26 12:00:00.200Z]
               }
             ] =
               Tracker.live_tracks(t)
    end

    # Where two tracks already sit on one object — the pile-up this rule stops
    # being made, seen from after it was made — one box may not hold both
    # alive, or the pile could never drain.
    test "only the most overlapping of several refusing tracks is marked seen" do
      nearer = [0.50, 0.50, 0.18, 0.12]

      # both refuse the drifted box (@stationary_match_iou is 0.7) and both are
      # above the suppression threshold, `nearer` by more
      assert_in_delta Tracker.iou(nearer, @car_drift), 0.636, 0.001
      assert_in_delta Tracker.iou(@parked_car, @car_drift), 0.5, 0.001

      {t, ids} =
        Enum.reduce(0..10, {Tracker.new(), nil}, fn n, {t, ids} ->
          {t, tagged, _} =
            track(t, [det("car", @parked_car), det("car", nearer)],
              media_ms: n * 1_000,
              observed_at: at(n * 1_000)
            )

          {t, ids || Enum.map(tagged, & &1.object_id)}
        end)

      assert [far_id, near_id] = ids
      assert [%Track{stationary: true}, %Track{stationary: true}] = Tracker.live_tracks(t)

      {t, tagged, events} =
        track(t, [det("car", @car_drift)], media_ms: 14_000, observed_at: at(14_000))

      assert tagged == []
      assert events == []

      seen_at = Map.new(Tracker.live_tracks(t), &{&1.object_id, &1.last_seen_at})
      assert seen_at[near_id] == at(14_000)
      assert seen_at[far_id] == at(10_000)

      # so the one the box did not vouch for still expires on its own clock
      {t, [], ended} = track(t, [], media_ms: 25_100)
      assert [{:ended, %Track{object_id: ^far_id, end_reason: :unseen}}] = ended
      assert [%Track{object_id: ^near_id}] = Tracker.live_tracks(t)
    end

    # The counterpart of "an exact IoU tie is broken deterministically": with
    # two tracks refusing the same box by the same margin, which one is marked
    # seen is decided by the sort key and never by map iteration order.
    test "an exact overlap tie between two refusing tracks is broken by id" do
      # pixel units again: an exact tie has to survive being computed two ways,
      # and 120/280 is one double however it is reached
      left = [600, 360, 20, 10]
      drift = [608, 360, 20, 10]
      right = [616, 360, 20, 10]

      assert Tracker.iou(left, drift) === Tracker.iou(right, drift)
      assert_in_delta Tracker.iou(left, drift), 0.4286, 0.001
      # and not with each other, or one would suppress the other's detections
      assert_in_delta Tracker.iou(left, right), 0.111, 0.001

      {t, ids} =
        Enum.reduce(0..10, {Tracker.new(), nil}, fn n, {t, ids} ->
          {t, tagged, _} =
            track(t, [det("car", left), det("car", right)],
              media_ms: n * 1_000,
              observed_at: at(n * 1_000)
            )

          {t, ids || Enum.map(tagged, & &1.object_id)}
        end)

      {t, [], []} = track(t, [det("car", drift)], media_ms: 14_000, observed_at: at(14_000))

      seen_at = Map.new(Tracker.live_tracks(t), &{&1.object_id, &1.last_seen_at})
      assert seen_at[Enum.min(ids)] == at(14_000)
      assert seen_at[Enum.max(ids)] == at(10_000)
    end

    test "a plugin-owned track is not a suppression candidate" do
      {t, [plugin_object], _} =
        track(Tracker.new(), [det("car", @parked_car, track_id: "c1")], plugin_ctx([]))

      # host mode (no track_id) against a plugin-owned track it overlaps at
      # 0.5: `assign_host/3` only ever considers host-owned tracks, so this
      # neither matches nor is suppressed by it
      {_t, [host_object], events} =
        track(t, [det("car", @car_drift)], plugin_ctx(media_ms: 200))

      assert [{:started, %Track{object_id: other, source: :host}}] = events
      refute other == plugin_object.object_id
      assert host_object.object_id == other
    end

    # `seen/3` deliberately leaves `last_seen_host_ms` alone, so the backstop
    # keeps counting from the last *adopted* observation. Without that, a
    # detection the tracker refuses every batch would hold a track alive for
    # ever — the one case where the media clock cannot bound it, because the
    # refusals themselves keep moving it.
    test "refusals cannot hold a track alive past the host-clock backstop" do
      {t, id} = parked(@parked_car, "car")

      # 10 x the extended bound (10 x 5 x 3_000) of host time since the parked
      # track's last match, which `parked/2` leaves at host 0: the last moment
      # it is alive
      {t, [], []} =
        track(t, [det("car", @car_drift)],
          media_ms: 14_000,
          observed_at: at(14_000),
          now_ms: 150_000
        )

      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)

      # one host millisecond later, with the media clock refreshed by this
      # batch's refusal too — so only the backstop can be what ends it
      {t, tagged, ended} =
        track(t, [det("car", @car_drift)],
          media_ms: 18_000,
          observed_at: at(18_000),
          now_ms: 150_001
        )

      assert tagged == []
      assert [{:ended, %Track{object_id: ^id, end_reason: :unseen} = final}] = ended
      assert_self_contained(final)
      assert Tracker.live_tracks(t) == []

      # and the object is tracked again on the next batch: the identity the
      # refusals were protecting is gone, so nothing refuses this one
      {_t, [tagged], events} =
        track(t, [det("car", @car_drift)],
          media_ms: 19_000,
          observed_at: at(19_000),
          now_ms: 150_002
        )

      assert [{:started, %Track{object_id: fresh}}] = events
      refute fresh == id
      assert tagged.object_id == fresh
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

  describe "suspension and adoption" do
    # `parked/1` leaves a stationary track last detected at media 10_000 and at
    # wall `at(10_000)`, which is the instant every gap below is measured from.
    # Every `suspend/3` here is handed that same instant as the cut — a stream
    # cut while it was still producing — so the two clocks the module keeps
    # apart coincide. A test that needs them apart passes a later cut and says
    # in its name which of the two it is about.
    #
    # The new epoch's media clock is deliberately set *ahead* of the old one's
    # in these tests. Media time is per-stream and the tracker treats it as
    # opaque, but only that direction exposes a clock the reset failed to
    # re-base: an old-epoch instant left behind by a pts that restarted near
    # zero yields a negative elapsed time, which every rule here already floors
    # at zero, so the bug would pass unseen.
    @box [0.0, 0.0, 0.4, 0.4]
    # IoU 1/3 with @box — the two-objects-side-by-side case, under
    # `@adoption_match_iou` (0.4), so it is nobody's identity
    @shift_2 [0.2, 0.0, 0.4, 0.4]
    # IoU 0.6: over the short tier's floor, under the long tier's
    @shift_1 [0.1, 0.0, 0.4, 0.4]
    # IoU 0.778: over `@stationary_match_iou` (0.7), under `@stationary_iou`
    # (0.8), so both tiers adopt it and the stillness rule calls it movement
    @shift_05 [0.05, 0.0, 0.4, 0.4]
    # IoU 0.905 with @box, 0.379 with @shift_2
    @shift_02 [0.02, 0.0, 0.4, 0.4]

    # Pixel units and exact binary ratios, for the two tests that pin the
    # adoption thresholds to the bit rather than to a band. `@brick` is
    # 1_000 x 1_000 and every box below sits wholly inside it, so the union is
    # `@brick`'s own area and the overlap is exactly the fraction of it the box
    # covers — the same trick the pixel-unit fixtures elsewhere in this file
    # use, and the only way to write "one thousandth under the constant"
    # without hoping a float lands where the arithmetic says.
    @brick [0, 0, 1000, 1000]
    # 400_000 / 1_000_000 = `@adoption_match_iou`
    @brick_40 [0, 0, 500, 800]
    # 399_000 / 1_000_000
    @brick_399 [0, 0, 500, 798]
    # 700_000 / 1_000_000 = `@stationary_match_iou`
    @brick_70 [0, 0, 1000, 700]
    # 699_000 / 1_000_000
    @brick_699 [0, 0, 1000, 699]

    # Small and tall, against the one 0.4 x 0.4 square the fixtures above
    # displace along x. `@adoption_match_iou`'s own reasoning is drawn from a
    # car-sized box a few pixels of drift wide, and nothing above is either
    # car-sized or displaced in y.
    #
    # 0.05 x 0.04 nudged along *both* axes: IoU 3/7, over the mover floor
    @small_car [0.40, 0.50, 0.05, 0.04]
    @small_car_drift [0.41, 0.51, 0.05, 0.04]
    # `@walker` (0.10 x 0.30) nudged 0.04 down the frame: IoU 13/17, over the
    # stationary floor
    @walker_nudge [0.30, 0.24, 0.10, 0.30]
    # and stepped 0.15 down it: IoU 1/3, under the mover floor — an overlap
    # that ignored the y axis would read both of these as 1.0
    @walker_stride [0.30, 0.35, 0.10, 0.30]

    test "a stream reset suspends the live host tracks instead of ending them" do
      {t, id} = parked(@box)
      {t, events, info} = Tracker.suspend(t, 128, at(10_000))

      # nothing ended, so nothing downstream is told anything
      assert events == []
      assert info == %{suspended: 1, ended: 0, at: at(10_000)}
      assert Tracker.live_tracks(t) == []

      assert [%Track{object_id: ^id, stationary: true, end_reason: nil}] =
               Tracker.suspended_tracks(t)

      # and it is still a track a checkpoint owes a final summary for
      assert [%Track{object_id: ^id}] = Tracker.checkpoint_tracks(t)
    end

    test "a suspended track is out of ordinary matching" do
      # far over the ordinary @iou_threshold (0.1): a *live* track would answer
      # to this box without hesitating
      assert_in_delta Tracker.iou(@box, @shift_2), 1 / 3, 0.001
      assert Tracker.iou(@box, @shift_2) > 0.1

      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, at(10_000))

      {t, [tagged], events} =
        track(t, [det("person", @shift_2)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(10_500)
        )

      assert [{:started, %Track{object_id: other}}] = events
      assert tagged.object_id == other
      refute other == id
      # the suspension is untouched: it was neither adopted nor spent
      assert [%Track{object_id: ^id}] = Tracker.suspended_tracks(t)
    end

    # The stitching-era form of the double-detection failure, on the same
    # fixtures. `adopt/4` runs before `suppress_duplicates/4`, so the track it
    # revives is in the live set by the time the leftover box is judged and is a
    # suppression candidate like any other — which it can only be if the
    # candidate list is read after the adoption rather than before it.
    test "a second box of a just-adopted object in the same batch is suppressed" do
      {t, id} = parked(@parked_car, "car")
      {t, [], _info} = Tracker.suspend(t, 128, at(10_000))

      # 300 ms of outage, so both boxes clear `@adoption_match_iou`; the exact
      # one wins the suspension and the 0.783 one is left with nothing to adopt
      {t, tagged, events} =
        track(t, [det("car", @parked_car), det("car", @car_double)],
          epoch: "epoch_two",
          media_ms: 22_000,
          observed_at: at(10_300)
        )

      assert [%{object_id: ^id, bbox: @parked_car}] = tagged
      assert [{:updated, %Track{object_id: ^id}}, {:adopted, %Track{object_id: ^id}}] = events
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)
      assert Tracker.suspended_tracks(t) == []
    end

    test "a short gap resumes a parked track's identity, its stillness and its clocks" do
      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, at(10_000))

      # 300 ms of outage, and a worse-scoring detection than the track's best
      {t, [tagged], events} =
        track(t, [det("person", @box, score: 0.4)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(10_300)
        )

      assert tagged.object_id == id
      # the whole event list: no `:started`, no `:ended`, and the resumed
      # summary immediately after the update it describes
      assert [{:updated, updated}, {:adopted, adopted}] = events
      assert updated == adopted
      assert adopted.object_id == id
      assert Tracker.suspended_tracks(t) == []

      # the epoch follows the track to the stream it is now being seen in...
      assert adopted.epoch == "epoch_two"
      # ...while everything wall-clock about it is the track it always was
      assert adopted.started_at == at(0)
      assert adopted.best_score == 0.9
      assert adopted.stationary
      assert adopted.stationary_since == at(10_000)
      # the settle window is not re-armed and the gap is not stillness anyone
      # saw: `stationary_ms` counts media time this tracker actually watched it
      # hold still, and it has watched none of the new epoch yet
      assert adopted.stationary_ms == 0

      # a second of the new epoch's media clock accrues a second, which is only
      # true if the adoption re-based `last_detected_ms`: left on the old
      # epoch's 10_000 this batch would have booked the 2_000 ms between two
      # streams' clocks as time spent parked
      {t, [_tagged], _events} =
        track(t, [det("person", @box)],
          epoch: "epoch_two",
          media_ms: 13_000,
          observed_at: at(11_300)
        )

      assert [%Track{object_id: ^id, stationary: true, stationary_ms: 1_000}] =
               Tracker.live_tracks(t)
    end

    test "an adopted track that was not stationary settles on the new epoch's clock" do
      held = [0.0, 0.0, 0.1, 0.3]
      # moves once, then holds — anchored at `held` as of media 1_000, and
      # nowhere near `stationary_after_ms` (10_000) of stillness by media 3_000
      {t, id} = moving([[0.0, 0.2, 0.1, 0.3], held, held, held])
      {t, [], info} = Tracker.suspend(t, 128, at(3_000))
      assert info.at == at(3_000)

      {t, [tagged], _events} =
        track(t, [det("person", held)],
          epoch: "epoch_two",
          media_ms: 13_000,
          observed_at: at(4_000)
        )

      assert tagged.object_id == id
      # the anchor's clock came with it: on the old epoch's 1_000 this box
      # would have read as 12_000 ms of stillness and flipped here
      assert [%Track{stationary: false}] = Tracker.live_tracks(t)

      {t, [_], events} =
        track(t, [det("person", held)],
          epoch: "epoch_two",
          media_ms: 22_999,
          observed_at: at(13_999)
        )

      assert ids(events, :became_stationary) == []

      {_t, [_], events} =
        track(t, [det("person", held)],
          epoch: "epoch_two",
          media_ms: 23_000,
          observed_at: at(14_000)
        )

      # exactly `stationary_after_ms` after the adoption, on the new clock
      assert ids(events, :became_stationary) == [id]
    end

    test "past the short bound only a stationary track is adoptable" do
      last = [0.0, 0.0, 0.1, 0.3]
      {mover, mover_id} = moving([[0.0, 0.2, 0.1, 0.3], last])
      {mover, [], _info} = Tracker.suspend(mover, 128, at(1_000))

      # 3_001 ms of absence, one past the camera's max_unseen_ms, and a box
      # the track's own — nothing geometric refuses it, only the tier
      {mover, [tagged], events} =
        track(mover, [det("person", last)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(1_000 + 3_001)
        )

      assert [{:started, %Track{object_id: fresh}}] = events
      assert tagged.object_id == fresh
      refute fresh == mover_id
      # refused, not spent: it waits out the rest of its window
      assert [%Track{object_id: ^mover_id}] = Tracker.suspended_tracks(mover)

      {parked, parked_id} = parked(@box)
      {parked, [], _info} = Tracker.suspend(parked, 128, at(10_000))

      {_parked, [tagged], events} =
        track(parked, [det("person", @box)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(10_000 + 3_001)
        )

      assert tagged.object_id == parked_id
      assert ids(events, :adopted) == [parked_id]
      assert ids(events, :started) == []
    end

    test "the tier boundary is max_unseen_ms exactly, and the tiers demand different overlap" do
      assert_in_delta Tracker.iou(@box, @shift_1), 0.6, 0.001
      assert_in_delta Tracker.iou(@box, @shift_05), 0.778, 0.001

      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, at(10_000))

      # absence of exactly max_unseen_ms is still the short tier, where 0.6 is
      # over `@adoption_match_iou`
      {_short, [tagged], _events} =
        track(t, [det("person", @shift_1)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(13_000)
        )

      assert tagged.object_id == id

      # one millisecond later, from the same suspension: the long tier, where
      # 0.6 is under `@stationary_match_iou` and buys nothing
      {_long, [tagged], events} =
        track(t, [det("person", @shift_1)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(13_001)
        )

      assert [{:started, %Track{object_id: other}}] = events
      assert tagged.object_id == other
      refute other == id

      # ...and 0.78, at the same instant, does
      {_long, [tagged], _events} =
        track(t, [det("person", @shift_05)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(13_001)
        )

      assert tagged.object_id == id
    end

    test "the tier is measured from the track's own last sighting, not from the cut" do
      {t, id} = parked(@box)
      # an empty batch: the camera is still being observed, this track is not
      {t, [], []} = track(t, [], media_ms: 11_000, observed_at: at(11_000))
      {t, [], info} = Tracker.suspend(t, 128, at(11_000))
      assert info.at == at(11_000)

      # 2_500 ms after the cut — inside max_unseen_ms if the cut were what
      # counted — but 3_500 ms since anything saw this track, which is not.
      # Same box the short tier adopts at in the test above.
      {t, [tagged], events} =
        track(t, [det("person", @shift_1)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(13_500)
        )

      assert [{:started, %Track{object_id: other}}] = events
      assert tagged.object_id == other
      refute other == id
      assert [%Track{object_id: ^id}] = Tracker.suspended_tracks(t)
    end

    test "a suspension is adoptable up to the window and ends where it was last seen" do
      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, at(10_000))

      # `@adoption_window_ms` (60_000) after the cut, to the millisecond
      {_adopted, [tagged], _events} =
        track(t, [det("person", @box)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(70_000)
        )

      assert tagged.object_id == id

      # one millisecond past it: the suspension is settled before this batch's
      # detections are matched, so the box that would have adopted it mints
      {expired, [tagged], events} =
        track(t, [det("person", @box)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(70_001)
        )

      assert [{:ended, final}, {:started, %Track{object_id: other}}] = events
      assert tagged.object_id == other
      refute other == id
      assert final.object_id == id
      assert final.end_reason == :stream_reset
      assert_self_contained(final)

      # the instant it was last actually seen, not the instant the waiting
      # stopped: a minute of hoping is bookkeeping, not observation
      assert final.last_seen_at == at(10_000)
      assert final.last_detected_at == at(10_000)
      assert final.started_at == at(0)
      assert final.stationary

      assert Tracker.suspended_tracks(expired) == []
    end

    test "expire_suspended/2 ends a lapsed suspension once, and needs a clock" do
      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, at(10_000))

      # inside the window, so nothing is owed yet
      {same, []} = Tracker.expire_suspended(t, at(70_000))
      assert [%Track{object_id: ^id}] = Tracker.suspended_tracks(same)

      # no clock at all: the caller's timer is what has one
      {unchanged, []} = Tracker.expire_suspended(t, nil)
      assert [%Track{object_id: ^id}] = Tracker.suspended_tracks(unchanged)

      {ended, [{:ended, final}]} = Tracker.expire_suspended(t, at(70_001))
      assert final.object_id == id
      assert final.end_reason == :stream_reset
      assert final.last_seen_at == at(10_000)

      # once, whoever asks again and however much later
      assert Tracker.suspended_tracks(ended) == []
      assert {^ended, []} = Tracker.expire_suspended(ended, at(999_999))
    end

    test "end_all/3 ends a suspension as the reset that made it, whatever reason it is given" do
      {t, suspended_id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, at(10_000))

      {t, [live], _events} =
        track(t, [det("cat", [0.6, 0.6, 0.2, 0.2])],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(10_100)
        )

      {emptied, events} = Tracker.end_all(t, :detection_disabled)

      # the live track ends of the thing that happened to it; the suspended one
      # ends of the thing that happened to it, which was the reset
      assert [{:ended, cat}, {:ended, ghost}] =
               Enum.sort_by(events, fn {:ended, track} -> track.label end)

      assert cat.object_id == live.object_id
      assert cat.end_reason == :detection_disabled
      assert ghost.object_id == suspended_id
      assert ghost.end_reason == :stream_reset
      assert ghost.last_seen_at == at(10_000)

      assert Tracker.live_tracks(emptied) == []
      assert Tracker.suspended_tracks(emptied) == []
    end

    test "a plugin-owned track is severed by the cut rather than suspended" do
      {t, [a], _events} =
        track(Tracker.new(), [det("person", @box, track_id: "t1")], plugin_ctx([]))

      {t, events, info} = Tracker.suspend(t, 128, at(0))

      assert [{:ended, final}] = events
      assert final.object_id == a.object_id
      assert final.source == :plugin
      assert final.end_reason == :stream_reset
      assert %{suspended: 0, ended: 1} = info
      assert DateTime.compare(info.at, at(0)) == :eq
      assert Tracker.suspended_tracks(t) == []
    end

    test "the suspended set is trimmed to the cap, oldest generation first" do
      # 100 ms apart across a month boundary, deliberately. Erlang term order
      # over a `%DateTime{}` is its fields in key order — `day` before `month`
      # before `year` — so on any two instants inside one month, sorting the
      # structs directly agrees with sorting the instants, and every other
      # fixture in this file would let that mistake through.
      older = ~U[2026-07-31 23:59:59.900Z]
      newer = ~U[2026-08-01 00:00:00.000Z]

      {t, [first], _events} =
        track(Tracker.new(), [det("person", @box)], media_ms: 0, observed_at: older)

      {t, [], _info} = Tracker.suspend(t, 2, older)

      {t, [second], _events} =
        track(t, [det("cat", [0.6, 0.6, 0.2, 0.2])],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: newer
        )

      # a camera reconnecting in a loop must not stack a generation of ghosts
      # per attempt: at a cap of one, the older suspension is the one that goes
      {t, events, info} = Tracker.suspend(t, 1, newer)

      assert [{:ended, %Track{object_id: ended_id, end_reason: :stream_reset}}] = events
      assert ended_id == first.object_id
      assert info == %{suspended: 1, ended: 1, at: newer}
      assert [%Track{object_id: id}] = Tracker.suspended_tracks(t)
      assert id == second.object_id
    end

    test "a live track outranks a suspended one for the same box" do
      {t, ghost} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, at(10_000))

      # under the adoption floor, so this mints rather than adopting
      {t, [fresh], _events} =
        track(t, [det("person", @shift_2)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(10_100)
        )

      refute fresh.object_id == ghost

      # a box the ghost would take at 0.9 and the live track only at 0.38 —
      # but the live pass runs first, and an object something is currently
      # seeing outranks the ghost of one nothing has seen since the cut
      assert Tracker.iou(@box, @shift_02) > 0.7
      assert Tracker.iou(@shift_2, @shift_02) > 0.1

      {t, [tagged], events} =
        track(t, [det("person", @shift_02)],
          epoch: "epoch_two",
          media_ms: 12_500,
          observed_at: at(10_600)
        )

      assert tagged.object_id == fresh.object_id
      assert ids(events, :adopted) == []
      assert [%Track{object_id: ^ghost}] = Tracker.suspended_tracks(t)
    end

    test "one box resumes one identity, however many suspensions it overlaps" do
      # Two generations of ghost, from two cuts a fifth of a second apart: a
      # parked car and, from the epoch after it, a walker that minted its own
      # identity because it was under the adoption floor from the car.
      {t, parked_id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, at(10_000))

      {t, [walker], _events} =
        track(t, [det("person", @shift_2)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(10_100)
        )

      refute walker.object_id == parked_id
      {t, [], _info} = Tracker.suspend(t, 128, at(10_200))
      assert length(Tracker.suspended_tracks(t)) == 2

      # a box between the two, adoptable by *both* on the mover tier
      assert_in_delta Tracker.iou(@box, @shift_05), 0.778, 0.001
      assert_in_delta Tracker.iou(@shift_2, @shift_05), 0.4545, 0.001

      {t, [tagged], events} =
        track(t, [det("person", @shift_05)],
          epoch: "epoch_three",
          media_ms: 20_000,
          observed_at: at(10_300)
        )

      # the better overlap takes it, and only it: one detection is one object,
      # so the second suspension is left waiting rather than revived beside it
      assert tagged.object_id == parked_id
      assert ids(events, :adopted) == [parked_id]
      assert ids(events, :started) == []
      assert [%Track{object_id: still_waiting}] = Tracker.suspended_tracks(t)
      assert still_waiting == walker.object_id
    end

    test "a suspension already past its window is collected by the next cut" do
      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, at(10_000))

      # No batch ever arrives, so the camera's last observation is still
      # at(10_000) — but the second cut is a minute and a bit after the first,
      # and the window this suspension is judged against is the one that
      # started at the first cut.
      {t, events, info} = Tracker.suspend(t, 128, at(70_001))

      assert [{:ended, %Track{object_id: ^id, end_reason: :stream_reset}}] = events
      assert info == %{suspended: 0, ended: 1, at: at(10_000)}
      assert Tracker.suspended_tracks(t) == []
    end

    test "a box a suspended track will not answer to is minted, not dropped as its duplicate" do
      last = [0.0, 0.0, 0.4, 0.4]
      {t, id} = moving([[0.2, 0.2, 0.4, 0.4], last])
      {t, [], _info} = Tracker.suspend(t, 128, at(1_000))

      # 0.6 overlap, which is over `@duplicate_suppression_iou` (0.4): an
      # unmatched *live* track this close would have this box dropped and be
      # marked seen by it. A suspended one is not in that pass either — it is
      # not a live track, and a drop would leave whatever is really there
      # untracked while the ghost it was blamed on cannot be seen at all.
      {_t, [tagged], events} =
        track(t, [det("person", @shift_1)],
          epoch: "epoch_two",
          media_ms: 13_000,
          observed_at: at(1_000 + 5_000)
        )

      assert [{:started, %Track{object_id: other}}] = events
      assert tagged.object_id == other
      refute other == id
    end

    test "a predicted box may not resume an identity, however well it overlaps" do
      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, at(10_000))

      # the plugin's own extrapolation of where the object would be if it were
      # still there — which, across a gap nothing observed, is the question
      {predicted, [tagged], events} =
        track(t, [det("person", @box, kind: "tracked")],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(10_300)
        )

      assert [{:started, %Track{object_id: other}}] = events
      assert tagged.object_id == other
      refute other == id
      assert [%Track{object_id: ^id}] = Tracker.suspended_tracks(predicted)

      # withheld rather than lost: from the same suspension, the same box
      # *detected* resumes the identity
      {detected, [tagged], events} =
        track(t, [det("person", @box)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(10_300)
        )

      assert tagged.object_id == id
      assert ids(events, :adopted) == [id]
      assert Tracker.suspended_tracks(detected) == []
    end

    test "an adopted track that came back where it was stays stationary, batch after batch" do
      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, at(10_000))

      # 0.905 overlap with the space it was parked in: the same car, seen a
      # couple of pixels off. It resumes already stationary — which is the
      # whole point of suspending rather than ending it, since
      # `Cairn.DetectionAggregator` refuses a stationary track as evidence —
      # and it stays that way. Four batches, because the failure this guards
      # against is a stillness window that only turns over after a few of them.
      {_t, adopting} =
        Enum.reduce(0..3, {t, nil}, fn n, {t, first} ->
          {t, [tagged], events} =
            track(t, [det("person", @shift_02)],
              epoch: "epoch_two",
              media_ms: 12_000 + n * 1_000,
              observed_at: at(10_300 + n * 1_000)
            )

          assert tagged.object_id == id
          assert tagged.stationary
          assert ids(events, :started_moving) == []

          assert [%Track{object_id: ^id, stationary: true, stationary_since: since}] =
                   Tracker.live_tracks(t)

          # the settle window never re-armed: this is the instant it first
          # held still, before the cut
          assert since == at(10_000)
          {t, first || events}
        end)

      assert ids(adopting, :adopted) == [id]
    end

    test "an adopted track whose box has shifted off its anchor reads as moving at once" do
      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, at(10_000))

      # 0.778 overlap: adoptable on either tier, and under `@stationary_iou`
      # (0.8), so it is a shift the stillness rule calls movement. It is called
      # that on the adopting batch, because `revive/3` empties the median
      # window — the four boxes that used to outvote this one belong to a
      # stream that is gone, and while they held the majority a car that drove
      # off during the outage went on reading as parked, which is to say as
      # something the aggregator refuses as evidence.
      {t, [tagged], events} =
        track(t, [det("person", @shift_05)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(10_300)
        )

      assert tagged.object_id == id
      assert ids(events, :adopted) == [id]
      assert ids(events, :started_moving) == [id]
      refute tagged.stationary
      assert [%Track{object_id: ^id, stationary: false}] = Tracker.live_tracks(t)

      # and it settles again on the new epoch's clock, from the box it moved to
      {t, [_], events} =
        track(t, [det("person", @shift_05)],
          epoch: "epoch_two",
          media_ms: 13_000,
          observed_at: at(11_300)
        )

      assert ids(events, :became_stationary) == []

      {_t, [_], events} =
        track(t, [det("person", @shift_05)],
          epoch: "epoch_two",
          media_ms: 22_000,
          observed_at: at(20_300)
        )

      # `stationary_after_ms` (10_000) after the adopting batch re-anchored it
      assert ids(events, :became_stationary) == [id]
    end

    test "the window runs from the cut, not from the camera's last sighting" do
      {t, id} = parked(@box)

      # the stream goes quiet at at(10_000) and ffmpeg only gives up on it
      # forty seconds later, so the cut and the last sighting are far apart
      {t, [], info} = Tracker.suspend(t, 128, at(50_000))
      # the outage *gap* is still reported to the last sighting — that is what
      # a gap is — and it is not what bounds the waiting
      assert info.at == at(10_000)

      # 50 s after the cut and 90 s after the last sighting: measured from the
      # sighting this suspension lapsed half a minute ago, measured from the
      # cut it has ten seconds left. Same box it was parked at, so the
      # stationary tier — the only one still open this far out — takes it back.
      {adopted, [tagged], events} =
        track(t, [det("person", @box)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(100_000)
        )

      assert tagged.object_id == id
      assert ids(events, :adopted) == [id]
      assert ids(events, :started) == []
      assert Tracker.suspended_tracks(adopted) == []

      # `@adoption_window_ms` (60_000) from the cut, to the millisecond
      {_last_chance, [tagged], _events} =
        track(t, [det("person", @box)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(110_000)
        )

      assert tagged.object_id == id

      # and one past it the box mints instead
      {_expired, [tagged], events} =
        track(t, [det("person", @box)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(110_001)
        )

      assert [{:ended, final}, {:started, %Track{object_id: other}}] = events
      assert tagged.object_id == other
      assert final.object_id == id
      assert final.end_reason == :stream_reset
      # the summary is still timestamped where the object was last seen, which
      # is a hundred seconds before the waiting stopped
      assert final.last_seen_at == at(10_000)
      refute other == id
    end

    test "the mover tier is capped short of an operator's max_unseen_ms" do
      last = [0.0, 0.0, 0.1, 0.3]
      {mover, mover_id} = moving([[0.0, 0.2, 0.1, 0.3], last])
      {mover, [], _info} = Tracker.suspend(mover, 128, at(1_000))

      # A deployment that has raised `max_unseen_ms` to 15 s to ride out slow
      # inference. That is patience with the plugin, not a claim about how far
      # a walker can get, so the mover tier still closes at
      # `@mover_adoption_max_ms` (3_000) and a box arriving one millisecond
      # later is a new object however well it overlaps.
      {_t, [tagged], events} =
        track(mover, [det("person", last)],
          epoch: "epoch_two",
          media_ms: 12_000,
          max_unseen_ms: 15_000,
          observed_at: at(1_000 + 3_001)
        )

      assert [{:started, %Track{object_id: other}}] = events
      assert tagged.object_id == other
      refute other == mover_id

      # a millisecond earlier, the same box under the same config resumes it
      {_t, [tagged], events} =
        track(mover, [det("person", last)],
          epoch: "epoch_two",
          media_ms: 12_000,
          max_unseen_ms: 15_000,
          observed_at: at(1_000 + 3_000)
        )

      assert tagged.object_id == mover_id
      assert ids(events, :adopted) == [mover_id]

      # below the cap the config is still what bounds the tier: a camera that
      # calls one second of absence extraordinary is taken at its word
      {_t, [tagged], events} =
        track(mover, [det("person", last)],
          epoch: "epoch_two",
          media_ms: 12_000,
          max_unseen_ms: 1_000,
          observed_at: at(1_000 + 1_001)
        )

      assert [{:started, %Track{object_id: fresh}}] = events
      assert tagged.object_id == fresh
      refute fresh == mover_id

      {_t, [tagged], events} =
        track(mover, [det("person", last)],
          epoch: "epoch_two",
          media_ms: 12_000,
          max_unseen_ms: 1_000,
          observed_at: at(1_000 + 1_000)
        )

      assert tagged.object_id == mover_id
      assert ids(events, :adopted) == [mover_id]
    end

    test "the mover tier's floor is @adoption_match_iou exactly" do
      assert Tracker.iou(@brick, @brick_40) === 0.4
      assert Tracker.iou(@brick, @brick_399) === 0.399

      {t, id} = parked(@brick)
      {t, [], _info} = Tracker.suspend(t, 128, at(10_000))

      # one second of absence, so this is the mover tier and 0.4 is its floor
      {_adopted, [tagged], events} =
        track(t, [det("person", @brick_40)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(11_000)
        )

      assert tagged.object_id == id
      assert ids(events, :adopted) == [id]

      # a thousandth under the floor mints instead
      {_minted, [tagged], events} =
        track(t, [det("person", @brick_399)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(11_000)
        )

      assert [{:started, %Track{object_id: other}}] = events
      assert tagged.object_id == other
      refute other == id
    end

    test "the stationary tier's floor is @stationary_match_iou exactly" do
      assert Tracker.iou(@brick, @brick_70) === 0.7
      assert Tracker.iou(@brick, @brick_699) === 0.699

      {t, id} = parked(@brick)
      {t, [], _info} = Tracker.suspend(t, 128, at(10_000))

      # past the mover tier, so 0.7 is being asked of the stationary tier's own
      # floor rather than of the one above
      {_adopted, [tagged], events} =
        track(t, [det("person", @brick_70)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(13_001)
        )

      assert tagged.object_id == id
      assert ids(events, :adopted) == [id]

      {_minted, [tagged], events} =
        track(t, [det("person", @brick_699)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(13_001)
        )

      assert [{:started, %Track{object_id: other}}] = events
      assert tagged.object_id == other
      refute other == id
    end

    test "a small box is adopted on the mover tier, displaced in both axes" do
      assert_in_delta Tracker.iou(@small_car, @small_car_drift), 3 / 7, 0.001

      {t, id} = parked(@small_car, "car")
      {t, [], _info} = Tracker.suspend(t, 128, at(10_000))

      {_t, [tagged], events} =
        track(t, [det("car", @small_car_drift)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(11_000)
        )

      assert tagged.object_id == id
      assert ids(events, :adopted) == [id]
      assert ids(events, :started) == []
    end

    test "a tall box is adopted on the stationary tier, displaced in y" do
      assert_in_delta Tracker.iou(@walker, @walker_nudge), 13 / 17, 0.001
      assert_in_delta Tracker.iou(@walker, @walker_stride), 1 / 3, 0.001

      {t, id} = parked(@walker)
      {t, [], _info} = Tracker.suspend(t, 128, at(10_000))

      # past the mover tier, so 0.765 is asked of the stationary floor
      {_t, [tagged], events} =
        track(t, [det("person", @walker_nudge)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(13_001)
        )

      assert tagged.object_id == id
      assert ids(events, :adopted) == [id]

      # the same box a stride further down the frame is somebody else, on the
      # tier that would have taken it most easily: an overlap that dropped the
      # y axis would read this as 1.0 and hand over the identity
      {_t, [tagged], events} =
        track(t, [det("person", @walker_stride)],
          epoch: "epoch_two",
          media_ms: 12_000,
          observed_at: at(11_000)
        )

      assert [{:started, %Track{object_id: other}}] = events
      assert tagged.object_id == other
      refute other == id
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
