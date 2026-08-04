defmodule Cairn.TrackerTest do
  use ExUnit.Case, async: true

  import Cairn.TrackAssertions
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Cairn.Observation
  alias Cairn.ObservationClock
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
  # both axes: IoU 0.783, which is the overlap the live failure's two boxes
  # had — far above @duplicate_suppression_iou and above @stationary_match_iou
  # too, so nothing about it looks like a second object
  @car_double [0.415, 0.505, 0.18, 0.12]
  # tall where the car boxes are wide, and displaced in y rather than x
  @walker [0.30, 0.20, 0.10, 0.30]
  # IoU 0.5 with @walker, the same overlap @car_drift has with @parked_car
  @walker_step [0.30, 0.30, 0.10, 0.30]

  # The stationary-hysteresis fixtures, and the measured ones: the car of the
  # live failure was about 0.17 by 0.09 of the frame, and the detector put
  # roughly 0.02 of drift on it in *y*. That is under a quarter of the box's
  # short axis and nothing like motion, but it is over a fifth of the box's
  # height in a single batch — an instantaneous rate dozens of times the
  # drift floor, which is what made the old geometry rule flap. What the
  # drift rate reads instead is the *mean*, and jitter that alternates has
  # none: the flapping fixture below holds the flag through sixty batches
  # of it.
  #
  # A wide box drifting on its *short* axis, deliberately. Every other box in
  # this file that moves at all moves along its own long axis (@car_drift in x
  # on a wide box, @walker_step in y on a tall one), and the stillness tests
  # above all park a 1.0 x 1.0 or 0.4 x 0.4 square — so "small", "wide" and
  # "displaced across the short side" are three dimensions this corpus
  # otherwise holds constant, and the live failure needed all three.
  @small_car [0.40, 0.50, 0.17, 0.09]
  @small_car_jitter [0.40, 0.52, 0.17, 0.09]
  # A creep of 0.004 per batch on the same box: 8e-6 of the frame per
  # millisecond at the 500 ms cadence, nearly nine times the drift floor for
  # a box this short — and IoU 0.915 against the box before it, so a rule
  # comparing consecutive boxes calls it motionless. This is the slow walk
  # the mean exists to catch, at the scale the parked car actually lives at:
  # each step is inside jitter, but the steps agree, and their mean crosses
  # the floor once the filter has seen enough of them.
  @small_car_creep 0.004

  defp det(label, bbox, opts \\ []) do
    %{
      label: label,
      bbox: bbox,
      score: Keyword.get(opts, :score, 0.9),
      track_id: Keyword.get(opts, :track_id),
      observation_kind: Keyword.get(opts, :kind, "detected")
    }
  end

  # `observed_at` defaults to the wall instant `at_ms` names, which is what the
  # ports produce: one clock advances the tracking decisions and the other dates
  # the same observation for a human. A test that needs them apart passes both.
  defp ctx(opts) do
    at_ms = Keyword.get(opts, :at_ms, 0)

    %{
      camera_id: Keyword.get(opts, :camera_id, "cam_a"),
      epoch: Keyword.get(opts, :epoch, "epoch_one"),
      at_ms: at_ms,
      observed_at: Keyword.get(opts, :observed_at, at(at_ms)),
      max_unseen_ms: Keyword.get(opts, :max_unseen_ms, @max_unseen),
      max_live_tracks: Keyword.get(opts, :max_live_tracks, 128),
      stationary_after_ms: Keyword.get(opts, :stationary_after_ms, @stationary_after),
      # Absent by default, which is what every test above this line wants: no
      # floor means no partition, so every object is stage one and association
      # behaves as it did before there were stages.
      min_score: Keyword.get(opts, :min_score)
    }
  end

  defp track(tracker, objects, opts \\ []), do: Tracker.track(tracker, objects, ctx(opts))

  defp ids(events, kind) do
    for {^kind, %Track{object_id: id}} <- events, do: id
  end

  # The wall instant an `at_ms` names, so a `stationary_since` — which is
  # `observed_at` data, not a clock the tracker reads — can be checked against
  # the step that set it.
  defp at(ms), do: DateTime.add(~U[2026-07-26 12:00:00Z], trunc(ms), :millisecond)

  # One object over `{at_ms, bbox}` (or `{at_ms, bbox, kind}`) steps,
  # returning the last step's `track/3` result. Every step's box overlaps the
  # one before it far above `@iou_threshold` — the stillness fixtures move by
  # jitter and creep, never by a jump — so identity is held by IoU throughout
  # and what these tests exercise is the stillness rule.
  defp feed(tracker, steps) do
    Enum.reduce(steps, {tracker, [], []}, fn step, {tracker, _tagged, _events} ->
      {ms, bbox, kind} =
        case step do
          {ms, bbox} -> {ms, bbox, "detected"}
          {ms, bbox, kind} -> {ms, bbox, kind}
        end

      track(tracker, [det("person", bbox, kind: kind)], at_ms: ms, observed_at: at(ms))
    end)
  end

  # One object of `label` detected every second at `box`, from 0 through
  # @stationary_after (10_000) on the observation clock: stationary as of the
  # last step, with `last_seen_ms` and `last_matched_ms` 10_000 and
  # `last_seen_at` at(10_000).
  defp parked(box, label \\ "person") do
    {tracker, id} =
      Enum.reduce(0..10, {Tracker.new(), nil}, fn n, {tracker, id} ->
        {tracker, [tagged], _events} =
          track(tracker, [det(label, box)], at_ms: n * 1_000, observed_at: at(n * 1_000))

        {tracker, id || tagged.object_id}
      end)

    assert [%Track{object_id: ^id, stationary: true}] = Tracker.live_tracks(tracker)
    {tracker, id}
  end

  # One object detected once per second of the observation clock along
  # `boxes`, from 0. It has moved on every step, so it is not stationary and
  # its still run is no older than the last evaluation its drift failed.
  defp moving(boxes, label \\ "person") do
    {tracker, id} =
      boxes
      |> Enum.with_index()
      |> Enum.reduce({Tracker.new(), nil}, fn {box, n}, {tracker, id} ->
        {tracker, [tagged], _events} =
          track(tracker, [det(label, box)], at_ms: n * 1_000, observed_at: at(n * 1_000))

        {tracker, id || tagged.object_id}
      end)

    assert [%Track{object_id: ^id, stationary: false}] = Tracker.live_tracks(tracker)
    {tracker, id}
  end

  # Two detections a second, which is a plausible inference rate and — the part
  # that matters — short enough that the excursions below are several
  # evaluations rather than one.
  @batch_ms 500

  # The small parked car of the hysteresis tests, detected every @batch_ms
  # from 0 through @stationary_after (10_000). It is stationary as of the
  # last step, its still run open since 0, with a converged filter reading
  # zero velocity.
  defp parked_small do
    {tracker, [tagged], _events} =
      feed(
        Tracker.new(),
        for(n <- 0..div(@stationary_after, @batch_ms), do: {n * @batch_ms, @small_car})
      )

    assert tagged.stationary
    tracker
  end

  # `boxes` fed one per @batch_ms starting at `from_ms`, with every event of
  # the run — the excursions are about what never happened.
  defp excursion(tracker, from_ms, boxes) do
    feed_all(
      tracker,
      for({bbox, n} <- Enum.with_index(boxes), do: {from_ms + n * @batch_ms, bbox})
    )
  end

  # The same car creeping `@small_car_creep` down the frame per batch.
  defp creep(n), do: [0.40, 0.50 + n * @small_car_creep, 0.17, 0.09]

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
  # reaching `track/3` crashes that camera's `Cairn.CameraTracker` on the
  # next same-label batch. Everything the ports feed it passes validate_det/1
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
      assert track.started_at == at(0)
      refute track.stale_predicted
    end

    test "same object keeps its id across overlapping frames" do
      {t, [a], _} = track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4])])
      {_t, [b], events} = track(t, [det("person", [0.12, 0.1, 0.2, 0.4])], at_ms: 200)

      assert a.object_id == b.object_id
      assert ids(events, :started) == []
      assert ids(events, :updated) == [a.object_id]
    end

    test "non-overlapping detection of same label gets a new id" do
      {t, [a], _} = track(Tracker.new(), [det("person", [0.0, 0.0, 0.1, 0.1])])
      {_t, [b], events} = track(t, [det("person", [0.8, 0.8, 0.1, 0.1])], at_ms: 200)

      refute a.object_id == b.object_id
      assert ids(events, :started) == [b.object_id]
    end

    test "labels never match each other even when overlapping" do
      {t, [a], _} = track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4])])
      {_t, [b], _} = track(t, [det("cat", [0.1, 0.1, 0.2, 0.4])], at_ms: 200)

      refute a.object_id == b.object_id
    end

    test "two objects tracked independently in one batch" do
      dets = [det("person", [0.1, 0.1, 0.2, 0.4]), det("person", [0.7, 0.1, 0.2, 0.4])]
      {t, [a, b], _} = track(Tracker.new(), dets)
      assert a.object_id != b.object_id

      moved = [det("person", [0.72, 0.1, 0.2, 0.4]), det("person", [0.12, 0.1, 0.2, 0.4])]
      {_t, [b2, a2], _} = track(t, moved, at_ms: 200)

      assert a2.object_id == a.object_id
      assert b2.object_id == b.object_id
    end

    test "the best score over the track's life is kept" do
      {t, _, _} = track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4], score: 0.6)])

      {t, _, [{:updated, high}]} =
        track(t, [det("person", [0.1, 0.1, 0.2, 0.4], score: 0.95)], at_ms: 200)

      {_t, _, [{:updated, low}]} =
        track(t, [det("person", [0.1, 0.1, 0.2, 0.4], score: 0.7)], at_ms: 400)

      assert high.best_score == 0.95
      assert low.score == 0.7
      assert low.best_score == 0.95
    end
  end

  describe "expiry" do
    # The batch-count rule this replaced expired after 5 missed batches: 5s at
    # 1 fps but 333ms at 15 fps. A clock spaced by frames makes both the same 3s.
    test "expires after max_unseen_ms at 1 fps" do
      {t, [a], _} = track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4])])

      {t, [], []} = track(t, [], at_ms: 2_000)
      {t, [], []} = track(t, [], at_ms: 3_000)
      {t, [], ended} = track(t, [], at_ms: 3_100)

      assert [{:ended, %Track{object_id: id, end_reason: :unseen} = final}] = ended
      assert id == a.object_id
      assert_self_contained(final)

      {_t, [b], _} = track(t, [det("person", [0.1, 0.1, 0.2, 0.4])], at_ms: 3_200)
      refute b.object_id == a.object_id
    end

    test "survives the same number of missed batches at 15 fps" do
      {t, [a], _} = track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4])])

      # 30 frames at 15 fps is 2s on the clock: still the same object
      t =
        Enum.reduce(1..30, t, fn n, t ->
          {t, [], []} = track(t, [], at_ms: n * 66.7)
          t
        end)

      {_t, [b], events} = track(t, [det("person", [0.1, 0.1, 0.2, 0.4])], at_ms: 2_100)

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
        track(t, [det("person", [0.1, 0.1, 0.2, 0.4], kind: "tracked")], at_ms: 4_000)

      assert a.stale_predicted
      assert tracked.stale_predicted

      {_t, [b], [{:updated, redetected}]} =
        track(t, [det("person", [0.1, 0.1, 0.2, 0.4])], at_ms: 4_100)

      assert b.object_id == a.object_id
      refute b.stale_predicted
      refute redetected.stale_predicted
    end
  end

  describe "plugin track ids are ignored" do
    # The wire still carries `track_id` per object and the protocol still
    # decodes it (see `Cairn.PluginProtocol`), so objects reaching the tracker
    # can have one. Nothing here may read it: identity is IoU and the summaries
    # say so.
    test "objects carrying track ids are tracked host-side, and the ids are not identity" do
      objects = [det("person", [0.0, 0.0, 0.1, 0.1], track_id: "t1")]
      {t, [a], [{:started, started}]} = track(Tracker.new(), objects)

      assert started.source == :host
      assert started.plugin_track_id == nil

      # the same id, on a box that does not overlap at all: IoU decides, so this
      # is a second object with a ULID of its own
      {_t, [b], events} =
        track(t, [det("person", [0.9, 0.9, 0.05, 0.05], track_id: "t1")], at_ms: 200)

      refute b.object_id == a.object_id
      assert [{:started, minted}] = events
      assert minted.object_id == b.object_id
      assert minted.source == :host
      assert minted.plugin_track_id == nil
    end

    test "an observation's ended_tracks reaches no context key and ends nothing" do
      observation = %Cairn.Observation{
        camera_id: "cam_a",
        epoch: "epoch_one",
        plugin_instance: "grp",
        at_ms: 0,
        observed_at: ~U[2026-07-26 12:00:00Z],
        objects: [%{label: "person", bbox: [0.1, 0.1, 0.2, 0.4], score: 0.9, track_id: "t1"}],
        ended_tracks: ["t1"]
      }

      policy = %{
        max_unseen_ms: @max_unseen,
        max_live_tracks: 128,
        stationary_after_ms: @stationary_after
      }

      context = Tracker.context(observation, "cam_a", policy)

      refute Map.has_key?(context, :ended_tracks)
      refute Map.has_key?(context, :tracking)

      {t, [tagged], events} = Tracker.track(Tracker.new(), observation.objects, context)

      # "t1" is named in `ended_tracks` and carried on the object, and the track
      # it would have ended is started and live instead
      assert [{:started, %Track{object_id: id, source: :host, plugin_track_id: nil}}] = events
      assert tagged.object_id == id
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)
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

    # old→new: the drift used to be a frame-wide box marching to x = 2.0. Boxes
    # are frame-normalized now — the motion filter's noise model is scaled by
    # height as a fraction of the frame and its predicted widths and heights
    # are capped at 1.0, so pixel-scale boxes stop matching (the origin is
    # free; it is the dimensions that assume the frame). The same walk is
    # scaled to stay in those units — the drift is a tenth of the box's width
    # per step, ten times the drift floor for a box this tall.
    test "a slow drift never reads stationary, however long it runs" do
      # each box overlaps the one before it well past 0.8, so a rule that
      # compared consecutive boxes would call this motionless; the steps
      # agree in direction, so their mean does not
      assert Tracker.iou([0.0, 0.35, 0.3, 0.3], [0.03, 0.35, 0.3, 0.3]) > 0.8

      steps = for n <- 0..20, do: {n * 1_000, [n * 0.03, 0.35, 0.3, 0.3]}
      {t, events} = feed_all(Tracker.new(), steps)

      # 20s of drift under a 10s threshold, the still run restarted on every
      # failed evaluation
      assert length(ids(events, :updated)) == 20
      assert for({:became_stationary, _} = e <- events, do: e) == []
      assert [%Track{stationary: false, stationary_ms: 0}] = Tracker.live_tracks(t)
    end

    test "detector jitter around a fixed point is absorbed by the mean" do
      base = [0.0, 0.0, 1.0, 1.0]
      spike = [0.25, 0.0, 1.0, 1.0]

      # a single spike reads far over the drift floor on its own; each one is
      # followed by the snap back, the readings alternate in sign, and the
      # mean of what alternates is nothing
      assert Tracker.iou(base, spike) < 0.8

      steps = for n <- 0..10, do: {n * 1_000, if(rem(n, 4) == 2, do: spike, else: base)}
      {_t, [tagged], events} = feed(Tracker.new(), steps)

      assert tagged.stationary
      assert [{:updated, _}, {:became_stationary, %Track{stationary_since: since}}] = events
      assert since == at(10_000)
    end

    test "the still run starts at the first detection, not at a predicted first frame" do
      box = [0.0, 0.0, 1.0, 1.0]

      {t, events} =
        feed_all(Tracker.new(), [{0, box, "tracked"} | for(n <- 1..10, do: {n * 1_000, box})])

      # the run starts at the detection at 1_000, so 10_000 is still short
      assert for({:became_stationary, _} = e <- events, do: e) == []

      {_t, [tagged], events} = feed(t, [{11_000, box}])
      assert tagged.stationary
      assert [{:updated, _}, {:became_stationary, %Track{stationary_since: since}}] = events
      assert since == at(11_000)
    end

    test "predicted observations neither advance nor reset stillness" do
      box = [0.0, 0.0, 1.0, 1.0]
      # displaced by half the box's width — a jump whose *evaluated* reading
      # would sit far over the drift floor — while still clearing
      # @iou_threshold (0.1) so the track matches it and the test is about the
      # stillness rule rather than about identity
      elsewhere = [0.5, 0.0, 1.0, 1.0]

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

    test "motion after a stationary stretch flips back once the failure sustains" do
      box = [0.0, 0.0, 1.0, 1.0]
      moved = [0.5, 0.0, 1.0, 1.0]

      {t, _, _} = feed(Tracker.new(), for(n <- 0..10, do: {n * 1_000, box}))

      # the smoothed drift needs a few evaluations to carry a real move
      {t, [held], _} = feed(t, [{11_000, moved}, {12_000, moved}])
      assert held.stationary

      # 13_000 is the first evaluation the smoothed drift fails, and it opens the exit
      # window rather than closing the flag: @stationary_exit_ms (2_500) of
      # unbroken failure is what closes it, so 14_000 and 15_000 are still
      # inside it and the flag is still set on all three.
      {t, held_events} = feed_all(t, for(n <- 13..15, do: {n * 1_000, moved}))

      assert for({:started_moving, _} = e <- held_events, do: e) == []
      assert [%Track{stationary: true}] = Tracker.live_tracks(t)

      {t, [tagged], events} = feed(t, [{16_000, moved}])

      refute tagged.stationary
      assert [{:updated, _}, {:started_moving, %Track{} = flipped}] = events
      refute flipped.stationary
      assert flipped.stationary_since == nil
      # the window accrues: the flag was set for every one of those batches, and
      # `stationary_ms` counts the time the flag was set
      assert flipped.stationary_ms == 5_000
      assert [%Track{stationary: false}] = Tracker.live_tracks(t)
    end

    test "stationary_ms is a total: it survives a stationary -> moving -> stationary cycle" do
      box = [0.0, 0.0, 1.0, 1.0]
      moved = [0.5, 0.0, 1.0, 1.0]

      {t, _, _} =
        feed(Tracker.new(), for(n <- 0..12, do: {n * 1_000, if(n > 10, do: moved, else: box)}))

      # the smoothed drift first fails at 13_000; the flag goes at 16_000, the
      # first evaluation @stationary_exit_ms (2_500) past it
      {t, _, _} = feed(t, for(n <- 13..15, do: {n * 1_000, moved}))
      {t, [tagged], events} = feed(t, [{16_000, moved}])
      refute tagged.stationary
      assert [_updated, {:started_moving, %Track{stationary_ms: 5_000}}] = events

      # old→new: the second stretch used to settle 10 s after the flip,
      # because the flip re-anchored on the moved box and the settle measured
      # pure geometry from there. The drift rule pays for real motion in time
      # instead: a full-frame box decays the jump's velocity estimate slowly,
      # evaluations keep failing until the mean is back under the floor —
      # measured, the still run holds from 27_000 — and the settle lands
      # `stationary_after_ms` later, at 37_000. Parking after being seen to
      # move reads stationary later than parking ever did; the moduledoc
      # names that the deliberate direction to fail in.
      {t, events} = feed_all(t, for(n <- 17..36, do: {n * 1_000, moved}))
      assert for({:became_stationary, _} = e <- events, do: e) == []

      # the second stretch is measured from where the run held, and adds to
      # the first
      {t, [tagged], events} = feed(t, [{37_000, moved}])
      assert tagged.stationary
      assert [_updated, {:became_stationary, %Track{stationary_ms: 5_000}}] = events

      {_t, _tagged, events} = feed(t, [{38_000, moved}, {39_000, moved}])
      assert [{:updated, %Track{stationary: true, stationary_ms: 7_000}}] = events
    end

    test "stillness is measured on every axis: y and height jitter, then a move in y" do
      base = [0.0, 0.0, 1.0, 1.0]
      lower = [0.0, 0.25, 1.0, 1.0]
      shorter = [0.0, 0.0, 1.0, 0.6]
      moved = [0.0, 0.5, 1.0, 1.0]

      # each spike alone reads far over the drift floor, on a different axis —
      # `lower` against the velocity floor, `shorter` against the growth floor
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

      # A real move in y, which the smoothed drift carries on its second
      # evaluation: it fails from 12_000, and the flag goes at 15_000 — the
      # first evaluation @stationary_exit_ms (2_500) past the first failure,
      # not the first failure itself.
      {t, events} = feed_all(t, for(n <- 11..15, do: {n * 1_000, moved}))

      assert [{:started_moving, %Track{stationary: false, last_seen_at: flipped_at}}] =
               for({:started_moving, _} = e <- events, do: e)

      assert flipped_at == at(15_000)
      assert [%Track{stationary: false, stationary_ms: 4_000}] = Tracker.live_tracks(t)
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
            track(tracker, [det("person", bbox)], at_ms: n * 1_000, observed_at: at(n * 1_000))

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

  describe "stationary exit hysteresis" do
    test "the fixtures straddle the drift floor the way the live failure did" do
      # Asserted by literal, because every test below writes the boxes and
      # never the numbers: a fixture nudged to something that no longer
      # straddles the floor would leave the whole block green and testing
      # nothing. The floor is @stationary_velocity_floor (0.1) of the box's
      # height per settle window — 0.9e-6 of the frame per millisecond for
      # the 0.09-tall car.
      floor = 0.1 * 0.09 / @stationary_after
      [_, y_car, _, h_car] = @small_car
      [_, y_jit, _, _] = @small_car_jitter

      # the jitter displaces the box by 0.02 in a single batch — over a fifth
      # of its height, and more than forty times the floor as an instantaneous
      # rate at the 500 ms cadence the excursions run at. Only its *mean* is
      # still: it alternates, and cancels.
      assert_in_delta abs(y_jit - y_car) / h_car, 0.222, 0.001
      assert abs(y_jit - y_car) / @batch_ms > 40 * floor

      # one creep step is the same displacement every batch — nearly nine
      # times the floor as a rate, and nothing about it alternates, so its
      # mean converges on the rate itself. Consecutive boxes still overlap at
      # 0.915: a rule comparing neighbours calls it motionless.
      assert_in_delta @small_car_creep / @batch_ms / floor, 8.888, 0.01
      assert_in_delta Tracker.iou(creep(3), creep(4)), 0.915, 0.001
    end

    test "a jitter excursion opens no window at all" do
      t = parked_small()

      # Three jittered batches and back. The old median failed on this for a
      # full second, absorbed only by the exit window; the mean does better —
      # measured, the excursion's smoothed drift peaks at 0.5e-6 against the
      # 0.9e-6 floor — so no evaluation fails and no window ever opens.
      {t, events} =
        excursion(t, 10_500, [
          @small_car_jitter,
          @small_car_jitter,
          @small_car_jitter,
          @small_car,
          @small_car,
          @small_car,
          @small_car
        ])

      assert ids(events, :started_moving) == []
      # not merely un-emitted: the flag itself never wavered, batch by batch,
      # which is what the camera tracker reads to decide the car is not evidence
      assert for({:updated, tr} <- events, do: tr.stationary) == List.duplicate(true, 7)
      assert [%Track{stationary: true, stationary_since: since}] = Tracker.live_tracks(t)
      assert since == at(10_000)
      # and no failure is pending behind the flag
      assert [%{pending_exit_ms: nil}] = Map.values(t.objects)
    end

    test "a two-second excursion flips nothing either, and the accrual never pauses" do
      t = parked_small()

      # Five jittered batches — the excursion that used to put two full
      # seconds of continuous failure on the old median. Sustained
      # displacement is where the mean climbs fastest, and five batches
      # still leaves it under the floor; the shift that never comes back
      # does cross it, six batches in, and that departure is the
      # window-closing test below.
      {t, events} =
        excursion(
          t,
          10_500,
          List.duplicate(@small_car_jitter, 5) ++ List.duplicate(@small_car, 3)
        )

      assert ids(events, :started_moving) == []
      assert [%Track{stationary: true, stationary_since: since}] = Tracker.live_tracks(t)
      assert since == at(10_000)

      # `stationary_ms` counts the time the flag was set, and it was set
      # throughout: 10_000 to 14_000 with nothing skipped over the excursion.
      assert [%Track{stationary_ms: 4_000}] = Tracker.live_tracks(t)
    end

    test "two excursions separated by a passing batch are not one long excursion" do
      t = parked_small()

      # Two of the two-second excursions above, back to back. Under the old
      # median this was four seconds of failure against a 2.5 s window, and
      # no flip only because the window measures an unbroken run and not a
      # total. Under the mean neither excursion fails an evaluation at all;
      # what this pins now is that excursions do not accumulate into
      # anything, however many of them run. The unbroken-run-not-total
      # property itself is the passing-evaluation test below.
      {t, first} =
        excursion(
          t,
          10_500,
          List.duplicate(@small_car_jitter, 5) ++ List.duplicate(@small_car, 3)
        )

      {t, second} =
        excursion(
          t,
          14_500,
          List.duplicate(@small_car_jitter, 5) ++ List.duplicate(@small_car, 3)
        )

      assert ids(first ++ second, :started_moving) == []
      assert [%Track{stationary: true, stationary_since: since}] = Tracker.live_tracks(t)
      assert since == at(10_000)
    end

    test "one passing evaluation ends a pending window outright" do
      t = parked_small()

      # A window opened by real creep: the smoothed drift crosses the floor
      # at 14_000, eight batches in. The internal peek here and below is
      # deliberate — an open window hides behind a true flag, so the flag
      # alone cannot pin it.
      {t, events} = excursion(t, 10_500, for(n <- 1..8, do: creep(n)))
      assert ids(events, :started_moving) == []
      assert [%{pending_exit_ms: 14_000}] = Map.values(t.objects)

      # Five seconds of seeded stretch: predicted boxes do not evaluate, so
      # the window neither advances nor clears while nothing is judged.
      {t, events} = feed_all(t, for(n <- 1..9, do: {14_000 + n * 500, creep(8), "tracked"}))
      assert ids(events, :started_moving) == []
      assert [%{pending_exit_ms: 14_000}] = Map.values(t.objects)

      # The car stopped where the creep left it. Spread over the five-second
      # gap, the closing detection's reading pulls the mean back under the
      # floor: one passing evaluation, and the window is gone — not paused,
      # not decayed into a credit, gone — with the flag never having wavered.
      # The window is a rule about continuity, not a total.
      {t, [tagged], events} = feed(t, [{19_000, creep(8)}])
      assert ids(events, :started_moving) == []
      assert tagged.stationary
      assert [%{pending_exit_ms: nil, stationary: true}] = Map.values(t.objects)
      assert [%Track{stationary_since: since}] = Tracker.live_tracks(t)
      assert since == at(10_000)
    end

    test "an excursion leaves nothing behind: the flag, its instant, the whole settle" do
      t = parked_small()

      # The excursion ends and the car is back where it was parked, for ten
      # seconds — long enough that a window left half-open, or a pending state
      # that decayed into anything other than "no failure is running", would
      # have had time to show.
      #
      # old→new: what the old version could not pin was the anchor's
      # stability — a car back in its own spot could not tell a stable anchor
      # from one that re-baselined onto the jitter. The mean has no anchor to
      # lose; what stability means for it is that the still run was never
      # restarted, which `stationary_since` below pins directly.
      {t, events} =
        excursion(
          t,
          10_500,
          List.duplicate(@small_car_jitter, 3) ++ List.duplicate(@small_car, 20)
        )

      assert ids(events, :started_moving) == []
      assert [%Track{stationary: true, stationary_since: since}] = Tracker.live_tracks(t)
      assert since == at(10_000)
      # the internal peek: a half-open window would hide behind the true flag
      assert [%{pending_exit_ms: nil}] = Map.values(t.objects)
    end

    test "a slow departure still leaves the flag: the run holds through the window" do
      t = parked_small()

      # The slow walk, on a parked car: 0.004 of drift per batch, every step
      # of it inside jitter of the step before it — and every step in the
      # same direction, so the mean accumulates toward the true rate as the
      # filter converges on it. The smoothed drift crosses the floor at
      # 14_000, eight batches in, and never comes back: a genuine departure,
      # and it flips @stationary_exit_ms later, at 16_500.
      #
      # This is where the run's stability is load-bearing. While the window
      # is open the drift goes on being averaged over the run the car was
      # parked in, which is what makes the window a test of sustained motion;
      # the settle-window average is also why the crossing takes eight
      # batches where the raw rate is nine times the floor from the first —
      # patience the exit window was already paying for under the old rule.
      {t, events} = excursion(t, 10_500, for(n <- 1..8, do: creep(n)))

      assert ids(events, :started_moving) == []

      {t, events} = excursion(t, 14_500, for(n <- 9..13, do: creep(n)))

      assert [{:started_moving, %Track{last_seen_at: flipped_at}}] =
               for({:started_moving, _} = e <- events, do: e)

      assert flipped_at == at(16_500)
      assert [%Track{stationary: false, stationary_since: nil}] = Tracker.live_tracks(t)
    end

    test "the window closes at @stationary_exit_ms exactly, and closes once" do
      t = parked_small()

      # The shift that stays: the box steps 0.02 and never comes back. The
      # step itself is jitter-sized, so the mean takes six batches to carry
      # it — the smoothed drift crosses the floor at 13_500 — and from there
      # the failure runs unbroken, because a displacement that holds keeps
      # the filter's decaying velocity in the average longer than the
      # average forgets it.
      {t, events} = excursion(t, 10_500, List.duplicate(@small_car_jitter, 11))
      assert ids(events, :started_moving) == []
      # internal peek: the open window is invisible from the flag
      assert [%{pending_exit_ms: 13_500, stationary: true}] = Map.values(t.objects)

      # One millisecond short of the window, from the same tracker state
      {_short, [tagged], events} = feed(t, [{13_500 + 2_499, @small_car_jitter}])
      assert ids(events, :started_moving) == []
      assert tagged.stationary

      # and exactly on it
      {flipped, [tagged], events} = feed(t, [{13_500 + 2_500, @small_car_jitter}])

      assert [{:started_moving, %Track{} = moved}] =
               for({:started_moving, _} = e <- events, do: e)

      refute tagged.stationary
      refute moved.stationary
      assert moved.stationary_since == nil
      # the moment `Cairn.CameraTracker` records is timed by this, and it
      # is the batch that closed the window rather than the one that opened it
      assert moved.last_seen_at == at(16_000)

      # once, not per failing evaluation: the flag is already clear and the
      # still run measures from the flip, so the settled shift that follows
      # is an ordinary settle
      {_t, more} = excursion(flipped, 16_500, List.duplicate(@small_car_jitter, 4))
      assert ids(more, :started_moving) == []
    end

    test "a detection gap neither closes a pending window nor clears it" do
      t = parked_small()

      # a window opened by real creep, as in the slow departure above —
      # peeked internally here and after the gap, since an open window is
      # invisible from the flag
      {t, events} = excursion(t, 10_500, for(n <- 1..8, do: creep(n)))
      assert ids(events, :started_moving) == []
      assert [%{pending_exit_ms: 14_000}] = Map.values(t.objects)

      # Predicted boxes across a stretch shorter than the passing-evaluation
      # test's gap but longer than what remains of @stationary_exit_ms. They
      # do not evaluate stillness, so they neither complete the window nor
      # clear it: time passing with nothing to judge is not evidence the car
      # left, and a gap that goes on is ended by the unseen bound.
      {t, events} = feed_all(t, for(n <- 9..12, do: {10_000 + n * 500, creep(n), "tracked"}))

      assert ids(events, :started_moving) == []
      assert [%Track{stationary: true}] = Tracker.live_tracks(t)
      assert [%{pending_exit_ms: 14_000}] = Map.values(t.objects)

      # the window is still open, and the next *detection* past it closes
      # it — the car kept creeping through the gap, so the closing reading
      # still fails, and the two failures bracket a stretch nothing
      # contradicted
      {_t, [tagged], events} = feed(t, [{16_500, creep(13)}])
      assert ids(events, :started_moving) != []
      refute tagged.stationary
    end

    test "the production flapping failure: alternating drift never fails an evaluation" do
      # The measured failure the hysteresis was built against, replayed
      # against the drift rule: the 0.17 x 0.09 parked car, 0.02 of detector
      # drift in y, at the ~300 ms cadence of the live system. The old
      # geometry rule flapped on this — the flag cleared every minute or so,
      # about ten spurious clips in 25 minutes — and the exit window was
      # sized to ride it out. The mean does not need riding out: the jittered
      # readings alternate in sign, so across sixty batches not one
      # evaluation fails and the window never opens, batch by batch — which
      # is strictly stronger than opening and being absorbed.
      cadence = 300

      t =
        Enum.reduce(0..34, Tracker.new(), fn n, t ->
          {t, [_], _} =
            track(t, [det("person", @small_car)],
              at_ms: n * cadence,
              observed_at: at(n * cadence)
            )

          t
        end)

      assert [%Track{stationary: true}] = Tracker.live_tracks(t)

      {_t, events} =
        Enum.reduce(1..60, {t, []}, fn n, {t, seen} ->
          box = if rem(n, 2) == 1, do: @small_car_jitter, else: @small_car
          ms = 10_200 + n * cadence

          {t, [tagged], events} = track(t, [det("person", box)], at_ms: ms, observed_at: at(ms))

          assert tagged.stationary
          # no evaluation failed: a failure while stationary opens the exit
          # window, and the window is never open
          assert [%{pending_exit_ms: nil}] = Map.values(t.objects)
          {t, seen ++ events}
        end)

      assert ids(events, :started_moving) == []
      assert for({:updated, tr} <- events, do: tr.stationary) == List.duplicate(true, 60)
    end
  end

  describe "stationary grace" do
    # @max_unseen is 3_000 and the tracker's @stationary_unseen_factor is 5, so
    # a stationary track's unseen bound is 15_000. `parked/1` leaves
    # `last_seen_ms` at 10_000, so the grace runs from 13_000 (past the plain
    # bound) to 25_000 (the extended one).
    test "a stationary track keeps its ULID across an occlusion past max_unseen_ms" do
      box = [0.0, 0.0, 0.4, 0.4]
      {t, id} = parked(box)

      # 4_000 unseen: a moving track would already be gone
      {t, [], events} = track(t, [], at_ms: 14_000)
      assert events == []

      {t, [tagged], events} =
        track(t, [det("person", box)], at_ms: 15_000, observed_at: at(15_000))

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
        track(t, [det("person", passer)], at_ms: 14_000, observed_at: at(14_000))

      assert [{:started, %Track{object_id: passer_id}}] = events
      assert tagged.object_id == passer_id
      refute passer_id == id
      assert Enum.map(Tracker.live_tracks(t), & &1.object_id) == Enum.sort([id, passer_id])

      # and the identity was held, not merely withheld: the parked object is
      # still itself when it is detected again at 5_000 unseen
      {_t, [redetected], events} =
        track(t, [det("person", box)], at_ms: 15_000, observed_at: at(15_000))

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
        track(t, [det("person", jitter)], at_ms: 11_000, observed_at: at(11_000))

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
        track(t, [det("person", jitter)], at_ms: 13_000, observed_at: at(13_000))

      assert tagged.object_id == id
      assert [{:updated, %Track{object_id: ^id}}] = events
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(seen)

      # one millisecond later, from the same parked tracker: in grace, so the
      # same box is refused and gets an identity of its own
      {refused, [tagged], events} =
        track(t, [det("person", jitter)], at_ms: 13_001, observed_at: at(13_001))

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
        track(t, [det("person", offset)], at_ms: 20_000, observed_at: at(20_000))

      assert tagged.object_id == id
      assert [{:updated, %Track{object_id: ^id}}] = events
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)
    end

    test "the grace has an end: extended bound for a stationary track, plain for a moving one" do
      box = [0.0, 0.0, 0.4, 0.4]
      {t, id} = parked(box)

      # a second track, elsewhere in the frame and never stationary, last seen
      # at the same 10_000
      {t, [mover], _} =
        track(t, [det("person", [0.6, 0.6, 0.2, 0.2])], at_ms: 10_000, observed_at: at(10_000))

      refute mover.object_id == id

      # 3_100 unseen: past max_unseen_ms (3_000) for the mover, and 3_100 of
      # the parked track's 15_000 (5 x 3_000)
      {t, [], events} = track(t, [], at_ms: 13_100)
      assert [{:ended, %Track{object_id: gone, end_reason: :unseen}}] = events
      assert gone == mover.object_id
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)

      # exactly at the extended bound (10_000 + 15_000): still live
      {t, [], []} = track(t, [], at_ms: 25_000)
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)

      {t, [], events} = track(t, [], at_ms: 25_100)
      assert [{:ended, %Track{object_id: ^id, end_reason: :unseen} = final}] = events
      assert_self_contained(final)
      assert Tracker.live_tracks(t) == []
    end
  end

  # The stream the old host-clock backstop existed for, now that there is one
  # clock and the protection lives in `Cairn.ObservationClock`: `media_ms`
  # frozen while host time runs on. These drive the real ingestion clock rather
  # than handing `ctx/1` an `at_ms`, because what is under test is the pair —
  # a clamp that keeps moving and a tracker that expires on what it moves.
  describe "a stalled pts" do
    # Under a stall the anchored value stands still, so the floor is the only
    # thing left advancing `at_ms`: one millisecond per *observation*, whatever
    # the host clock says. Every bound below is therefore counted in
    # observations, which is why this block scales the policy down — at the
    # file's own @max_unseen a stalled stream needs 150_000 of them to reach the
    # far side of the extended grace.
    @stalled_unseen 30
    @stalled_after 100
    # Anything: the point is that it never changes.
    @frozen_pts 5_000.0

    defp stalled_ctx(at_ms, opts) do
      opts
      |> Keyword.merge(
        at_ms: at_ms,
        max_unseen_ms: @stalled_unseen,
        stationary_after_ms: @stalled_after
      )
      |> ctx()
    end

    # A second of host time per observation.
    @host_step_ms 1_000

    # The ingestion state of a stalled stream: the clock, and the host instant
    # the next observation is stamped at. Host time is *driven* rather than read
    # — `stamp/3` takes `now_ms` — so "a second of host time after the last" is
    # a property of the test rather than of how fast the loop happens to run.
    defp stalled_ingest, do: {ObservationClock.new(), 0}

    # `count` observations of a stream whose pts never advances, each stamped
    # @host_step_ms of host time after the last, so nothing here is standing
    # still except the pts. Returns the last batch's `track/3` result beside the
    # ingestion state, to feed the next stretch.
    defp stall(tracker, ingest, objects, count, opts \\ []) do
      Enum.reduce(1..count, {tracker, ingest, [], []}, fn _n,
                                                          {tracker, {clock, now_ms}, _tagged,
                                                           _events} ->
        {observation, clock} =
          ObservationClock.stamp(
            clock,
            %Observation{epoch: "epoch_one", media_ms: @frozen_pts},
            now_ms
          )

        {tracker, tagged, events} =
          Tracker.track(tracker, objects, stalled_ctx(observation.at_ms, opts))

        {tracker, {clock, now_ms + @host_step_ms}, tagged, events}
      end)
    end

    test "expires a stationary track at the extended bound, and a moving one at the plain one" do
      parked_box = [0.0, 0.0, 0.4, 0.4]
      mover_box = [0.6, 0.6, 0.2, 0.2]

      # @stalled_after + 1 observations of the same box: the last one is
      # exactly `stationary_after_ms` past the anchor
      {t, ingest, [tagged], _events} =
        stall(Tracker.new(), stalled_ingest(), [det("person", parked_box)], 101)

      id = tagged.object_id
      assert [%Track{object_id: ^id, stationary: true}] = Tracker.live_tracks(t)

      # one batch that also carries a mover, which has moved by definition —
      # it is seen once and never again, so it never settles
      {t, ingest, tagged, _events} =
        stall(t, ingest, [det("person", parked_box), det("person", mover_box)], 1)

      assert [_parked, %{object_id: mover_id}] = tagged
      refute mover_id == id

      # nothing is detected from here on, so only the clamp is moving the clock.
      # @stalled_unseen + 1 observations later the mover is unseen past the
      # plain bound; the parked one is a fifth of the way through its grace
      {t, ingest, [], events} = stall(t, ingest, [], 31)
      assert [{:ended, %Track{object_id: ^mover_id, end_reason: :unseen}}] = events
      assert [%Track{object_id: ^id, stationary: true}] = Tracker.live_tracks(t)

      # 5 x @stalled_unseen from the parked track's last detection, to the
      # observation: the last one at which it is alive
      {t, ingest, [], []} = stall(t, ingest, [], 119)
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)

      {t, _ingest, [], events} = stall(t, ingest, [], 1)
      assert [{:ended, %Track{object_id: ^id, end_reason: :unseen} = final}] = events
      assert_self_contained(final)
      assert Tracker.live_tracks(t) == []
    end

    test "a pts that restarts mid-epoch neither rewinds the clock nor expires the scene" do
      box = [0.0, 0.0, 0.4, 0.4]
      clock = ObservationClock.new()

      {first, clock} =
        ObservationClock.stamp(
          clock,
          %Observation{epoch: "epoch_one", media_ms: 900_000.0},
          System.monotonic_time(:millisecond)
        )

      # the pts restarts near zero, which is what a plugin's own respawn looks
      # like from here: fifteen minutes backwards inside one epoch
      {restarted, _clock} =
        ObservationClock.stamp(
          clock,
          %Observation{epoch: "epoch_one", media_ms: 0.0},
          System.monotonic_time(:millisecond)
        )

      assert restarted.at_ms > first.at_ms

      {t, [a], _} =
        Tracker.track(Tracker.new(), [det("person", box)], stalled_ctx(first.at_ms, []))

      {t, [b], events} =
        Tracker.track(t, [det("person", box)], stalled_ctx(restarted.at_ms, []))

      # the whole event list, so "nothing ended" cannot be satisfied by a
      # tracker that emitted nothing at all
      assert [{:updated, %Track{object_id: updated}}] = events
      assert updated == a.object_id
      assert b.object_id == a.object_id
      assert [%Track{stationary_ms: 0}] = Tracker.live_tracks(t)
    end

    test "a restart after a long stall resumes tracking time rather than jumping to the host" do
      box = [0.0, 0.0, 0.4, 0.4]

      # A stretch of frozen pts: the floor moves `at_ms` by one millisecond an
      # observation while the host moves by a second, so the two are ninety-odd
      # *seconds* apart by the end. That difference is the lag, and it is what a
      # re-anchor at `now_ms` would hand the very next observation in one step.
      # Short of @stalled_after, so the box below is still a moving track and
      # gets the plain bound rather than the grace.
      {t, {clock, now_ms}, [tagged], _events} =
        stall(Tracker.new(), stalled_ingest(), [det("person", box)], 99)

      id = tagged.object_id
      lag = now_ms - clock.at_ms
      assert lag > 3_000

      # the pts restarts inside the same epoch — the plugin's own ffmpeg
      # respawning under an epoch nothing cut
      {restarted, _clock} =
        ObservationClock.stamp(clock, %Observation{epoch: "epoch_one", media_ms: 0.0}, now_ms)

      # continuity, not `now_ms`: exactly one floor step past where tracking
      # time already was
      assert restarted.at_ms == clock.at_ms + 1

      {t, [b], events} = Tracker.track(t, [det("person", box)], stalled_ctx(restarted.at_ms, []))

      # the whole event list, so "nothing expired" cannot be satisfied by a
      # tracker that emitted nothing at all. Anchored at `now_ms` this track is
      # `lag` milliseconds unseen at a bound of @stalled_unseen, so every live
      # track in the scene would end `:unseen` here and be re-minted below
      assert [{:updated, %Track{object_id: ^id}}] = events
      assert b.object_id == id
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)
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
          at_ms: 14_000,
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

      # and the clock really moved: 25_100 is past the extended bound
      # measured from the parked track's last *match* (10_000 + 15_000) and
      # inside it measured from the refusal (14_000 + 15_000)
      {t, [], []} = track(t, [], at_ms: 25_100)
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)

      {t, [], ended} = track(t, [], at_ms: 29_100)
      assert [{:ended, %Track{object_id: ^id, end_reason: :unseen} = final}] = ended
      assert_self_contained(final)
      assert Tracker.live_tracks(t) == []
    end

    test "a fragment of a parked object's box is dropped, not minted" do
      assert_in_delta Tracker.iou(@parked_car, @car_fragment), 0.45, 0.001

      {t, id} = parked(@parked_car, "car")

      {t, tagged, events} =
        track(t, [det("car", @car_fragment)], at_ms: 14_000, observed_at: at(14_000))

      assert tagged == []
      assert events == []
      assert [%Track{object_id: ^id, bbox: @parked_car}] = Tracker.live_tracks(t)
    end

    test "a same-label box below the threshold is a new object: it mints, and marks nothing" do
      assert_in_delta Tracker.iou(@parked_car, @car_neighbour), 1 / 3, 0.001

      {t, id} = parked(@parked_car, "car")

      {t, [tagged], events} =
        track(t, [det("car", @car_neighbour)], at_ms: 14_000, observed_at: at(14_000))

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
        track(t, [det("person", @car_drift)], at_ms: 14_000, observed_at: at(14_000))

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
      # the overlap the two boxes of the observed failure had: nothing about
      # it looks like a second object — it is over @stationary_match_iou (0.7),
      # let alone @duplicate_suppression_iou
      assert_in_delta Tracker.iou(@parked_car, @car_double), 0.783, 0.001

      {t, id} = parked(@parked_car, "car")

      # one second after the track's last sighting, so no grace is involved:
      # the track takes the first box at the base @iou_threshold
      {t, tagged, events} =
        track(t, [det("car", @parked_car), det("car", @car_double, score: 0.95)],
          at_ms: 11_000,
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
          at_ms: 11_000,
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

    # Exact ratios on purpose, so this is the one place in the suite where `>=`
    # and `>` on the threshold give different answers. Every coordinate below
    # is a dyadic rational, so both areas and the intersection are computed
    # with nothing to round and the single division lands on `0.4` (and `0.35`)
    # exactly — which is what the pixel-unit boxes this used to be written with
    # bought, before the frame-normalized motion filter made pixel units
    # unmatchable.
    test "the suppression threshold includes its own boundary" do
      box = [0.25, 0.25, 0.625, 0.25]
      exactly = [0.25, 0.25, 0.25, 0.25]
      under = [0.25, 0.25, 0.21875, 0.25]

      assert Tracker.iou(box, exactly) === 0.4
      assert Tracker.iou(box, under) === 0.35

      {t, id} = parked(box, "car")

      {_t, tagged, events} =
        track(t, [det("car", exactly)], at_ms: 14_000, observed_at: at(14_000))

      assert tagged == []
      assert events == []

      # the same tracker, a sliver of width less: below the threshold, so it
      # is a new object again
      {_t, [tagged], events} =
        track(t, [det("car", under)], at_ms: 14_000, observed_at: at(14_000))

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
          at_ms: 14_000,
          observed_at: at(14_000)
        )

      # from here it is detected every second at the drifted box. The refusal
      # took the track out of its grace, so the base threshold matches
      {t, seen_ids, started} =
        Enum.reduce(15_000..20_000//1_000, {t, [], []}, fn ms, {t, seen_ids, started} ->
          {t, [tagged], events} =
            track(t, [det("car", @car_drift, score: 0.7)], at_ms: ms, observed_at: at(ms))

          {t, [tagged.object_id | seen_ids], started ++ ids(events, :started)}
        end)

      assert length(seen_ids) == 6
      assert Enum.uniq(seen_ids) == [id]
      assert started == []
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)
    end

    # A refusal every 4_000 is refused every time: each mark leaves the next
    # batch 4_000 unseen, back inside the grace.
    test "repeated refusals mint nothing and leave the stillness window untouched" do
      {t, id} = parked(@parked_car, "car")

      t =
        Enum.reduce([14_000, 18_000, 22_000, 26_000, 30_000], t, fn ms, t ->
          {t, [], []} = track(t, [det("car", @car_drift)], at_ms: ms, observed_at: at(ms))
          assert [%Track{object_id: ^id, bbox: @parked_car}] = Tracker.live_tracks(t)
          t
        end)

      # five refusals left the still run and the motion filter exactly as
      # parked. Adopting the drifted box now still reads as *still*: the one
      # step it moved is spread over the 21 s since the last detection,
      # nothing the drift floor can see — which is only true if none of the
      # five refusals fed the filter or restarted the run
      {_t, [tagged], events} =
        track(t, [det("car", @car_drift)], at_ms: 31_000, observed_at: at(31_000))

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
          at_ms: 200,
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
        track(t, [det("person", @walker_step)], at_ms: 200, observed_at: at(200))

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
              at_ms: n * 1_000,
              observed_at: at(n * 1_000)
            )

          {t, ids || Enum.map(tagged, & &1.object_id)}
        end)

      assert [far_id, near_id] = ids
      assert [%Track{stationary: true}, %Track{stationary: true}] = Tracker.live_tracks(t)

      {t, tagged, events} =
        track(t, [det("car", @car_drift)], at_ms: 14_000, observed_at: at(14_000))

      assert tagged == []
      assert events == []

      seen_at = Map.new(Tracker.live_tracks(t), &{&1.object_id, &1.last_seen_at})
      assert seen_at[near_id] == at(14_000)
      assert seen_at[far_id] == at(10_000)

      # so the one the box did not vouch for still expires on its own clock
      {t, [], ended} = track(t, [], at_ms: 25_100)
      assert [{:ended, %Track{object_id: ^far_id, end_reason: :unseen}}] = ended
      assert [%Track{object_id: ^near_id}] = Tracker.live_tracks(t)
    end

    # The counterpart of "an exact IoU tie is broken deterministically": with
    # two tracks refusing the same box by the same margin, which one is marked
    # seen is decided by the sort key and never by map iteration order.
    test "an exact overlap tie between two refusing tracks is broken by id" do
      # dyadic coordinates again: an exact tie has to survive being computed
      # two ways, and 3/7 out of these is one double however it is reached
      # (old→new: the same three boxes scaled out of pixel units into the
      # frame-normalized ones the motion filter requires)
      left = [0.125, 0.25, 0.3125, 0.125]
      drift = [0.25, 0.25, 0.3125, 0.125]
      right = [0.375, 0.25, 0.3125, 0.125]

      assert Tracker.iou(left, drift) === Tracker.iou(right, drift)
      assert_in_delta Tracker.iou(left, drift), 0.4286, 0.001
      # and not with each other, or one would suppress the other's detections
      assert_in_delta Tracker.iou(left, right), 0.111, 0.001

      {t, ids} =
        Enum.reduce(0..10, {Tracker.new(), nil}, fn n, {t, ids} ->
          {t, tagged, _} =
            track(t, [det("car", left), det("car", right)],
              at_ms: n * 1_000,
              observed_at: at(n * 1_000)
            )

          {t, ids || Enum.map(tagged, & &1.object_id)}
        end)

      {t, [], []} = track(t, [det("car", drift)], at_ms: 14_000, observed_at: at(14_000))

      seen_at = Map.new(Tracker.live_tracks(t), &{&1.object_id, &1.last_seen_at})
      assert seen_at[Enum.min(ids)] == at(14_000)
      assert seen_at[Enum.max(ids)] == at(10_000)
    end

    # `seen/3` deliberately leaves `last_matched_ms` alone, so the refusal bound
    # keeps counting from the last *adopted* observation. Without that, a
    # detection the tracker refuses every batch would hold a track alive for
    # ever — the one case the unseen rule cannot bound, because the refusals
    # themselves keep moving the clock it reads.
    #
    # The bound is scaled by the same `unseen_bound/2` the unseen rule is, and
    # this is where that matters: on the plain bound it would end this parked
    # track at 10 x 3_000 from its last match, thirteen seconds after the first
    # refusal below rather than well past the second.
    test "refusals cannot hold a track alive past the refusal bound" do
      {t, id} = parked(@parked_car, "car")

      # Every batch here is more than @max_unseen (3_000) after the one before
      # it, which is the regime the loop needs and the only one it exists in: a
      # refusal marks the track seen, so a batch any sooner would find it out of
      # its grace and match the same box at @iou_threshold. Each of these finds
      # it back in the grace, refuses, and marks it seen again.
      {t, [], []} = track(t, [det("car", @car_drift)], at_ms: 14_000)
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)

      {t, [], []} = track(t, [det("car", @car_drift)], at_ms: 156_999)
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)

      # 10 x the extended bound (10 x 5 x 3_000) since the parked track's last
      # match at 10_000: the last moment it is alive
      {t, [], []} = track(t, [det("car", @car_drift)], at_ms: 160_000)
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)

      # past it, with this batch's refusal having refreshed `last_seen_ms` too
      # — so only the refusal bound can be what ends it
      {t, tagged, ended} = track(t, [det("car", @car_drift)], at_ms: 163_001)

      assert tagged == []
      assert [{:ended, %Track{object_id: ^id, end_reason: :unseen} = final}] = ended
      assert_self_contained(final)
      assert Tracker.live_tracks(t) == []

      # and the object is tracked again on the next batch: the identity the
      # refusals were protecting is gone, so nothing refuses this one
      {_t, [tagged], events} = track(t, [det("car", @car_drift)], at_ms: 164_000)

      assert [{:started, %Track{object_id: fresh}}] = events
      refute fresh == id
      assert tagged.object_id == fresh
    end
  end

  describe "bounded live set" do
    test "at the live-track cap the least recently seen track is evicted with a final" do
      capped = fn opts -> Keyword.put(opts, :max_live_tracks, 2) end

      # three boxes far enough apart that none of them matches or suppresses
      # another: what is under test is the cap, not the geometry
      first = [0.0, 0.0, 0.05, 0.05]
      second = [0.5, 0.5, 0.05, 0.05]
      third = [0.9, 0.9, 0.05, 0.05]

      {t, [a], _} = track(Tracker.new(), [det("person", first)], capped.([]))
      {t, [b], _} = track(t, [det("person", second)], capped.(at_ms: 100))

      # only the second box is re-detected, so the first is the least recently
      # seen of the two
      {t, _, _} = track(t, [det("person", second)], capped.(at_ms: 200))

      {{t, [c], events}, log} =
        with_log(fn -> track(t, [det("person", third)], capped.(at_ms: 300)) end)

      assert log =~ "live-track cap"

      assert [{:ended, %Track{end_reason: :evicted} = final}, {:started, %Track{}}] = events
      assert final.object_id == a.object_id
      assert_self_contained(final)

      # the cap holds, and it retired the right one
      assert Enum.map(Tracker.live_tracks(t), & &1.object_id) ==
               Enum.sort([b.object_id, c.object_id])
    end
  end

  test "an exact IoU tie is broken deterministically, not by map order" do
    same = [0.1, 0.1, 0.2, 0.4]
    {t, [a, b], _} = track(Tracker.new(), [det("person", same), det("person", same)])
    refute a.object_id == b.object_id

    # both candidates overlap perfectly; only the total sort key separates them
    {_t, [c], _} = track(t, [det("person", same)], at_ms: 200)
    assert c.object_id == Enum.min([a.object_id, b.object_id])
  end

  describe "end_all/2" do
    test "ends every live track with the given reason and returns a fresh tracker" do
      dets = [det("person", [0.1, 0.1, 0.2, 0.4]), det("cat", [0.7, 0.1, 0.2, 0.4])]
      {t, tagged, _} = track(Tracker.new(), dets)

      {fresh, events} = Tracker.end_all(t, :stream_reset)

      assert Enum.sort(ids(events, :ended)) == Enum.sort(Enum.map(tagged, & &1.object_id))
      assert Enum.all?(events, fn {:ended, track} -> track.end_reason == :stream_reset end)
      for {:ended, track} <- events, do: assert_self_contained(track)
      assert Tracker.live_tracks(fresh) == []

      # nothing matches across the cut
      {_t, [a], _} = track(fresh, [det("person", [0.1, 0.1, 0.2, 0.4])], at_ms: 200)
      refute a.object_id in Enum.map(tagged, & &1.object_id)
    end
  end

  describe "suspension and adoption" do
    # `parked/1` leaves a stationary track last seen at 10_000 on the
    # observation clock, which is the instant every gap below is measured from.
    # Every `suspend/3` here is handed that same instant as the cut — a stream
    # cut while the stream was still producing — so the track's own absence and
    # the waiting since the cut coincide. A test that needs the two apart
    # passes a later cut and says in its name which of them it is about.
    #
    # The new epoch's batches carry on from that same clock, because it is the
    # host's and not either stream's pts: an epoch boundary is a gap nothing
    # observed, not a discontinuity in the numbers.
    @box [0.0, 0.0, 0.4, 0.4]
    # IoU 1/3 with @box — the two-objects-side-by-side case, under
    # `@stitch_iou` (0.4), so it is nobody's identity
    @shift_2 [0.2, 0.0, 0.4, 0.4]
    # IoU 0.6: over `@stitch_iou` with room to spare, so it is adopted anywhere
    # inside the window — and over `@duplicate_suppression_iou` (no looser
    # than the stitch, equal today), so a *live* track this close would
    # suppress it instead
    @shift_1 [0.1, 0.0, 0.4, 0.4]
    # IoU 0.778: over `@stitch_iou`, so it is adopted — displaced an eighth
    # of the box's height, the shift the old geometry rule called movement
    # and the re-seeded filter deliberately does not (see the shifted
    # adoption test)
    @shift_05 [0.05, 0.0, 0.4, 0.4]
    # IoU 0.905 with @box, 0.379 with @shift_2
    @shift_02 [0.02, 0.0, 0.4, 0.4]

    # Exact binary ratios, for the test that pins the stitch threshold to the
    # bit rather than to a band. `@brick` is 1000/1024 of the frame wide and
    # every box below sits wholly inside it, so the union is `@brick`'s own
    # area and the overlap is exactly the fraction of it the box covers. Every
    # width is a dyadic rational over 1024, so nothing rounds before the single
    # division — the only way to write "one thousandth under the constant"
    # without hoping a float lands where the arithmetic says. (old→new: this
    # used to be a 1_000 x 1_000 pixel brick; boxes are frame-normalized now,
    # because the motion filter's predicted dimensions are capped at the
    # frame — a pixel-wide brick would coast at width 1.0 and stop matching
    # itself. The origin is free; the dimensions are what assume the frame.)
    @brick [0.0, 0.0, 0.9765625, 1.0]
    # 400/1024 over 1000/1024 = `@stitch_iou`
    @brick_40 [0.0, 0.0, 0.390625, 1.0]
    # 399/1024 over 1000/1024
    @brick_399 [0.0, 0.0, 0.3896484375, 1.0]

    # Small and tall, against the one 0.4 x 0.4 square the fixtures above
    # displace along x. `@stitch_iou`'s own reasoning is drawn from a
    # car-sized box a few pixels of drift wide, and nothing above is either
    # car-sized or displaced in y.
    #
    # 0.05 x 0.04 nudged along *both* axes: IoU 3/7, over the floor. Named
    # apart from the module's own `@small_car` deliberately: that one is a
    # different box for a different rule, and a module attribute redefined
    # halfway down a file silently changes meaning for everything after it.
    @small_car_adopt [0.40, 0.50, 0.05, 0.04]
    @small_car_drift [0.41, 0.51, 0.05, 0.04]
    # `@walker` (0.10 x 0.30) nudged 0.04 down the frame: IoU 13/17, well over
    # the floor
    @walker_nudge [0.30, 0.24, 0.10, 0.30]
    # and stepped 0.15 down it: IoU 1/3, under the floor — an overlap
    # that ignored the y axis would read both of these as 1.0
    @walker_stride [0.30, 0.35, 0.10, 0.30]

    test "a stream reset suspends the live host tracks instead of ending them" do
      {t, id} = parked(@box)
      {t, events, info} = Tracker.suspend(t, 128, 10_000)

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
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      {t, [tagged], events} =
        track(t, [det("person", @shift_2)],
          epoch: "epoch_two",
          at_ms: 10_500
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
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      # Both boxes clear `@stitch_iou`; the exact one wins the suspension and
      # the 0.783 one is left with nothing to adopt
      {t, tagged, events} =
        track(t, [det("car", @parked_car), det("car", @car_double)],
          epoch: "epoch_two",
          at_ms: 10_300
        )

      assert [%{object_id: ^id, bbox: @parked_car}] = tagged
      assert [{:updated, %Track{object_id: ^id}}, {:adopted, %Track{object_id: ^id}}] = events
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)
      assert Tracker.suspended_tracks(t) == []
    end

    # `revive/3` does not touch `bbox`, so the leftover box is judged against
    # the ghost's *pre-cut* box, not the box that just adopted it. The two
    # boxes here straddle that distinction: each clears `@stitch_iou` against
    # the ghost, but they sit at 0.22 to each other — below suppression's
    # floor — so this only suppresses if the candidate box is the ghost's own.
    # (This is also why `@stitch_iou` may not sink below
    # `@duplicate_suppression_iou`: judged against a box adoption could not
    # have accepted, the twin would mint beside the resumed identity.)
    test "the leftover is judged against the ghost's own box, not the adopter's" do
      adopter = [0.454, 0.50, 0.18, 0.12]
      twin = [0.34, 0.50, 0.18, 0.12]

      assert_in_delta Tracker.iou(@parked_car, adopter), 0.538, 0.001
      assert_in_delta Tracker.iou(@parked_car, twin), 0.5, 0.001
      assert_in_delta Tracker.iou(adopter, twin), 0.224, 0.001

      {t, id} = parked(@parked_car, "car")
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      {t, tagged, events} =
        track(t, [det("car", adopter), det("car", twin)],
          epoch: "epoch_two",
          at_ms: 10_300
        )

      # the closer box wins the suspension; the twin is suppressed, not minted
      assert [%{object_id: ^id, bbox: ^adopter}] = tagged
      assert [{:updated, %Track{object_id: ^id}}, {:adopted, %Track{object_id: ^id}}] = events
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)
      assert Tracker.suspended_tracks(t) == []
    end

    test "a short gap resumes a parked track's identity, its stillness and its clocks" do
      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      # 300 ms of outage, and a worse-scoring detection than the track's best
      {t, [tagged], events} =
        track(t, [det("person", @box, score: 0.4)],
          epoch: "epoch_two",
          at_ms: 10_300
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
      # saw: `stationary_ms` counts the time this tracker actually watched it
      # hold still, and it has watched none of the new epoch yet
      assert adopted.stationary_ms == 0

      # a second past the adoption accrues a second, which is only true if the
      # adoption moved `last_detected_ms` to the adopting batch: left at 10_000
      # this batch would have booked the whole outage as time spent parked
      {t, [_tagged], _events} =
        track(t, [det("person", @box)],
          epoch: "epoch_two",
          at_ms: 11_300
        )

      assert [%Track{object_id: ^id, stationary: true, stationary_ms: 1_000}] =
               Tracker.live_tracks(t)
    end

    test "an adopted track that was not stationary settles from the adoption" do
      held = [0.0, 0.0, 0.1, 0.3]
      # moves once, then holds — its still run no older than the move at
      # 1_000, and nowhere near `stationary_after_ms` (10_000) of stillness
      # by 3_000
      {t, id} = moving([[0.0, 0.2, 0.1, 0.3], held, held, held])
      {t, [], info} = Tracker.suspend(t, 128, 3_000)
      assert info.at == at(3_000)

      {t, [tagged], _events} =
        track(t, [det("person", held)],
          epoch: "epoch_two",
          at_ms: 4_000
        )

      assert tagged.object_id == id
      # the still run restarted at the adoption: left where it was, the
      # outage itself would have read as 3_000 ms of stillness towards the
      # settle
      assert [%Track{stationary: false}] = Tracker.live_tracks(t)

      {t, [_], events} =
        track(t, [det("person", held)],
          epoch: "epoch_two",
          at_ms: 13_999
        )

      assert ids(events, :became_stationary) == []

      {_t, [_], events} =
        track(t, [det("person", held)],
          epoch: "epoch_two",
          at_ms: 14_000
        )

      # exactly `stationary_after_ms` after the adoption, on the new clock
      assert ids(events, :became_stationary) == [id]
    end

    # The single-tier contract, in one test: inside the window, adoption asks
    # for `@stitch_iou` of overlap and for nothing else. The mover at thirty
    # seconds and the 0.6 boxes at 13_001 and 70_000 ms of absence were
    # refusals under the two-tier rule this replaced — each minted a second
    # identity for an object that was already tracked — and they pin the
    # behaviour change; the 10_001 and 13_000 ms iterations sat inside the
    # old short tier and pin that the loose rule did not move what already
    # adopted.
    test "one threshold and one window: neither the absence nor the flag is asked" do
      assert_in_delta Tracker.iou(@box, @shift_1), 0.6, 0.001

      last = [0.0, 0.0, 0.1, 0.3]
      {mover, mover_id} = moving([[0.0, 0.2, 0.1, 0.3], last])
      {mover, [], _info} = Tracker.suspend(mover, 128, 1_000)

      # A track that was moving when the stream died, gone for thirty seconds —
      # ten times the camera's `max_unseen_ms` — and back in its own last box.
      {mover, [tagged], events} =
        track(mover, [det("person", last)],
          epoch: "epoch_two",
          at_ms: 31_000
        )

      assert tagged.object_id == mover_id
      assert ids(events, :adopted) == [mover_id]
      assert ids(events, :started) == []
      assert Tracker.suspended_tracks(mover) == []

      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      # A parked track and a box at 0.6: adopted the same at one millisecond of
      # absence and at a minute of it, the two instants the old boundary sat
      # between.
      for at_ms <- [10_001, 13_000, 13_001, 70_000] do
        {_t, [tagged], events} =
          track(t, [det("person", @shift_1)], epoch: "epoch_two", at_ms: at_ms)

        assert tagged.object_id == id
        assert ids(events, :adopted) == [id]
      end

      # And the operator's patience with a slow plugin is not consulted either
      # way: a camera calling one second of absence extraordinary, and one
      # riding out fifteen, get the same answer to the same geometry.
      for max_unseen_ms <- [1_000, 15_000] do
        {_t, [tagged], events} =
          track(t, [det("person", @shift_1)],
            epoch: "epoch_two",
            max_unseen_ms: max_unseen_ms,
            at_ms: 20_000
          )

        assert tagged.object_id == id
        assert ids(events, :adopted) == [id]
      end
    end

    test "a suspension is adoptable up to the window and ends where it was last seen" do
      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      # `@adoption_window_ms` (60_000) after the cut, to the millisecond
      {_adopted, [tagged], _events} =
        track(t, [det("person", @box)],
          epoch: "epoch_two",
          at_ms: 70_000
        )

      assert tagged.object_id == id

      # one millisecond past it: the suspension is settled before this batch's
      # detections are matched, so the box that would have adopted it mints
      {expired, [tagged], events} =
        track(t, [det("person", @box)],
          epoch: "epoch_two",
          at_ms: 70_001
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

    test "expire_suspended/2 ends a lapsed suspension once" do
      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      # inside the window, so nothing is owed yet
      {same, []} = Tracker.expire_suspended(t, 70_000)
      assert [%Track{object_id: ^id}] = Tracker.suspended_tracks(same)

      {ended, [{:ended, final}]} = Tracker.expire_suspended(t, 70_001)
      assert final.object_id == id
      assert final.end_reason == :stream_reset
      assert final.last_seen_at == at(10_000)

      # once, whoever asks again and however much later
      assert Tracker.suspended_tracks(ended) == []
      assert {^ended, []} = Tracker.expire_suspended(ended, 999_999)
    end

    test "end_all/2 ends a suspension as the reset that made it, whatever reason it is given" do
      {t, suspended_id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      {t, [live], _events} =
        track(t, [det("cat", [0.6, 0.6, 0.2, 0.2])],
          epoch: "epoch_two",
          at_ms: 10_100
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

    test "the suspended set is trimmed to the cap, oldest generation first" do
      # Two cuts 100 ms apart, each with its own generation of ghost.
      {t, [first], _events} = track(Tracker.new(), [det("person", @box)], at_ms: 0)

      {t, [], _info} = Tracker.suspend(t, 2, 0)

      {t, [second], _events} =
        track(t, [det("cat", [0.6, 0.6, 0.2, 0.2])],
          epoch: "epoch_two",
          at_ms: 100
        )

      # a camera reconnecting in a loop must not stack a generation of ghosts
      # per attempt: at a cap of one, the older suspension is the one that goes
      {t, events, info} = Tracker.suspend(t, 1, 100)

      assert [{:ended, %Track{object_id: ended_id, end_reason: :stream_reset}}] = events
      assert ended_id == first.object_id
      assert info == %{suspended: 1, ended: 1, at: at(100)}
      assert [%Track{object_id: id}] = Tracker.suspended_tracks(t)
      assert id == second.object_id
    end

    test "a live track outranks a suspended one for the same box" do
      {t, ghost} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      # under the adoption floor, so this mints rather than adopting
      {t, [fresh], _events} =
        track(t, [det("person", @shift_2)],
          epoch: "epoch_two",
          at_ms: 10_100
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
          at_ms: 10_600
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
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      {t, [walker], _events} =
        track(t, [det("person", @shift_2)],
          epoch: "epoch_two",
          at_ms: 10_100
        )

      refute walker.object_id == parked_id
      {t, [], _info} = Tracker.suspend(t, 128, 10_200)
      assert length(Tracker.suspended_tracks(t)) == 2

      # a box between the two, adoptable by *both* of them
      assert_in_delta Tracker.iou(@box, @shift_05), 0.778, 0.001
      assert_in_delta Tracker.iou(@shift_2, @shift_05), 0.4545, 0.001

      {t, [tagged], events} =
        track(t, [det("person", @shift_05)],
          epoch: "epoch_three",
          at_ms: 10_300
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
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      # No batch ever arrives, so the camera's last observation is still
      # at(10_000) — but the second cut is a minute and a bit after the first,
      # and the window this suspension is judged against is the one that
      # started at the first cut.
      {t, events, info} = Tracker.suspend(t, 128, 70_001)

      assert [{:ended, %Track{object_id: ^id, end_reason: :stream_reset}}] = events
      assert info == %{suspended: 0, ended: 1, at: at(10_000)}
      assert Tracker.suspended_tracks(t) == []
    end

    test "a box a suspended track will not answer to is minted, not dropped as its duplicate" do
      last = [0.0, 0.0, 0.4, 0.4]
      {t, id} = moving([[0.2, 0.2, 0.4, 0.4], last])
      {t, [], _info} = Tracker.suspend(t, 128, 1_000)

      # A *predicted* box — chiefly what adoption refuses now that its
      # threshold is no looser than duplicate suppression's; the loser of a contended
      # suspension is refused too, but would then be legitimately suppressed
      # against the revived track — so this is the only way left to ask the
      # question. At 0.6 it is far over
      # `@duplicate_suppression_iou` (0.4): an unmatched *live* track this
      # close would have this box dropped and be marked seen by it. A suspended
      # one is not in that pass either — it is not a live track, and a drop
      # would leave whatever is really there untracked while the ghost it was
      # blamed on cannot be seen at all.
      {_t, [tagged], events} =
        track(t, [det("person", @shift_1, kind: "tracked")],
          epoch: "epoch_two",
          at_ms: 1_000 + 5_000
        )

      assert [{:started, %Track{object_id: other}}] = events
      assert tagged.object_id == other
      refute other == id
    end

    test "a predicted box may not resume an identity, however well it overlaps" do
      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      # the plugin's own extrapolation of where the object would be if it were
      # still there — which, across a gap nothing observed, is the question
      {predicted, [tagged], events} =
        track(t, [det("person", @box, kind: "tracked")],
          epoch: "epoch_two",
          at_ms: 10_300
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
          at_ms: 10_300
        )

      assert tagged.object_id == id
      assert ids(events, :adopted) == [id]
      assert Tracker.suspended_tracks(detected) == []
    end

    test "an adopted track that came back where it was stays stationary, batch after batch" do
      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      # 0.905 overlap with the space it was parked in: the same car, seen a
      # couple of pixels off. It resumes already stationary — which is the
      # whole point of suspending rather than ending it, since
      # `Cairn.CameraTracker` refuses a stationary track as evidence —
      # and it stays that way. Four batches, because the failure this guards
      # against is a rule that needs a few batches before it starts believing
      # the new epoch.
      {_t, adopting} =
        Enum.reduce(0..3, {t, nil}, fn n, {t, first} ->
          {t, [tagged], events} =
            track(t, [det("person", @shift_02)],
              epoch: "epoch_two",
              at_ms: 12_000 + n * 1_000,
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

    test "an adopted track that shifted during the outage resumes stationary, and stays" do
      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      # 0.778 overlap: well over `@stitch_iou`, so the shifted box resumes
      # the identity. old→new, and a conscious semantic change: the old
      # anchor kept its box across the cut, called this shift a failure on
      # the adopting batch itself, and flipped the flag a window later. The
      # drift rule has no geometry memory to carry across a gap nothing
      # observed: `revive/3` drops the filter, the adopting detection
      # re-seeds it, and a re-seeded filter has zero velocity — so the car
      # resumes stationary wherever in the frame it is adopted, and stays
      # that way while it holds still there, judged by the ordinary rule
      # from the second detection of the new epoch on. The moduledoc owns
      # this as the one place the rule is weaker than the geometry it
      # replaced; an association that reasons about observation gaps
      # (OC-SORT's re-update, roadmap step 7) is where the lost evidence
      # would come back.
      {t, [tagged], events} =
        track(t, [det("person", @shift_05)],
          epoch: "epoch_two",
          at_ms: 10_300
        )

      assert tagged.object_id == id
      assert ids(events, :adopted) == [id]
      assert ids(events, :started_moving) == []
      assert tagged.stationary

      # not merely unflipped on the adopting batch: it holds through and
      # past the old rule's exit window, still parked in its new spot
      {t, events} =
        Enum.reduce([11_300, 12_300, 13_300, 14_300], {t, []}, fn ms, {t, seen} ->
          {t, [tagged], events} =
            track(t, [det("person", @shift_05)], epoch: "epoch_two", at_ms: ms)

          assert tagged.stationary
          {t, seen ++ events}
        end)

      assert ids(events, :started_moving) == []

      assert [%Track{object_id: ^id, stationary: true, stationary_since: since}] =
               Tracker.live_tracks(t)

      # the settle window never re-armed: the instant is still the pre-cut one
      assert since == at(10_000)
    end

    test "the window runs from the cut, not from the camera's last sighting" do
      {t, id} = parked(@box)

      # the stream goes quiet at at(10_000) and ffmpeg only gives up on it
      # forty seconds later, so the cut and the last sighting are far apart
      {t, [], info} = Tracker.suspend(t, 128, 50_000)
      # the outage *gap* is still reported to the last sighting — that is what
      # a gap is — and it is not what bounds the waiting
      assert info.at == at(10_000)

      # 50 s after the cut and 90 s after the last sighting: measured from the
      # sighting this suspension lapsed half a minute ago, measured from the
      # cut it has ten seconds left, and the waiting is the only clock
      # adoption reads. Same box it was parked at, so it takes it back.
      {adopted, [tagged], events} =
        track(t, [det("person", @box)],
          epoch: "epoch_two",
          at_ms: 100_000
        )

      assert tagged.object_id == id
      assert ids(events, :adopted) == [id]
      assert ids(events, :started) == []
      assert Tracker.suspended_tracks(adopted) == []

      # `@adoption_window_ms` (60_000) from the cut, to the millisecond
      {_last_chance, [tagged], _events} =
        track(t, [det("person", @box)],
          epoch: "epoch_two",
          at_ms: 110_000
        )

      assert tagged.object_id == id

      # and one past it the box mints instead
      {_expired, [tagged], events} =
        track(t, [det("person", @box)],
          epoch: "epoch_two",
          at_ms: 110_001
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

    test "the adoption floor is @stitch_iou exactly, at any absence" do
      assert Tracker.iou(@brick, @brick_40) === 0.4
      assert Tracker.iou(@brick, @brick_399) === 0.399

      {t, id} = parked(@brick)
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      # One second of absence, then thirteen: the first is where the old short
      # tier asked 0.4, the second where the old long tier asked 0.7. One
      # number now answers both, and the same one refuses a thousandth under.
      for at_ms <- [11_000, 23_001] do
        {_adopted, [tagged], events} =
          track(t, [det("person", @brick_40)], epoch: "epoch_two", at_ms: at_ms)

        assert tagged.object_id == id
        assert ids(events, :adopted) == [id]

        # a thousandth under the floor mints instead
        {_minted, [tagged], events} =
          track(t, [det("person", @brick_399)], epoch: "epoch_two", at_ms: at_ms)

        assert [{:started, %Track{object_id: other}}] = events
        assert tagged.object_id == other
        refute other == id
      end
    end

    test "a small box is adopted, displaced in both axes" do
      assert_in_delta Tracker.iou(@small_car_adopt, @small_car_drift), 3 / 7, 0.001

      {t, id} = parked(@small_car_adopt, "car")
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      {_t, [tagged], events} =
        track(t, [det("car", @small_car_drift)],
          epoch: "epoch_two",
          at_ms: 11_000
        )

      assert tagged.object_id == id
      assert ids(events, :adopted) == [id]
      assert ids(events, :started) == []
    end

    test "a tall box is adopted, displaced in y" do
      assert_in_delta Tracker.iou(@walker, @walker_nudge), 13 / 17, 0.001
      assert_in_delta Tracker.iou(@walker, @walker_stride), 1 / 3, 0.001

      {t, id} = parked(@walker)
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      # thirteen seconds of absence, which the threshold does not ask about
      {_t, [tagged], events} =
        track(t, [det("person", @walker_nudge)],
          epoch: "epoch_two",
          at_ms: 13_001
        )

      assert tagged.object_id == id
      assert ids(events, :adopted) == [id]

      # the same box a stride further down the frame is somebody else, at a
      # second of absence rather than thirteen: an overlap that dropped the
      # y axis would read this as 1.0 and hand over the identity
      {_t, [tagged], events} =
        track(t, [det("person", @walker_stride)],
          epoch: "epoch_two",
          at_ms: 11_000
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

  # A walker crossing the frame at a twentieth of it per batch, which at the
  # 500 ms batches the coasting tests use is an ordinary pace. Every box is
  # 0.1 x 0.1 and in frame throughout, so nothing there is testing the motion
  # filter's clamps.
  @mover_step 0.05
  defp mover(n), do: [0.10 + n * @mover_step, 0.5, 0.1, 0.1]

  # The motion filter of one live track: internal state, reachable nowhere else
  # — `Cairn.Track` deliberately does not carry it.
  defp filter(tracker, id), do: tracker.objects[id].kalman

  # Five detected batches, enough for the filter to have a heading: the tracker
  # at 2_000 with one track on `mover(4)`.
  defp walked do
    {tracker, id} =
      Enum.reduce(0..4, {Tracker.new(), nil}, fn n, {tracker, id} ->
        {tracker, [tagged], _events} =
          track(tracker, [det("person", mover(n))], at_ms: n * 500, observed_at: at(n * 500))

        {tracker, id || tagged.object_id}
      end)

    {tracker, id}
  end

  describe "coasted predictions" do
    test "a mover is matched through a gap the frozen box would have lost it in" do
      {t, id} = walked()

      # two batches nothing detected it in: the track is untouched, so its
      # filter coasts once each
      {t, [], []} = track(t, [], at_ms: 2_500, observed_at: at(2_500))
      {t, [], []} = track(t, [], at_ms: 3_000, observed_at: at(3_000))

      # where the walk had got to by then, and nowhere near where the track's
      # box was frozen: the pre-Kalman matcher compared this with mover(4) and
      # had nothing to match, so the walker would have minted a second identity
      resumed = mover(7)
      assert Tracker.iou(mover(4), resumed) < 0.1

      {t, [tagged], events} = track(t, [det("person", resumed)], at_ms: 3_500)

      assert tagged.object_id == id
      assert ids(events, :started) == []
      assert [%Track{object_id: ^id, bbox: ^resumed}] = Tracker.live_tracks(t)
    end

    test "a seeded stretch holds the filter exactly, mean and covariance" do
      {t, id} = walked()
      held = filter(t, id)

      # four seeded batches, each matched by the track it belongs to: the
      # plugin re-reporting a sighting it already made is not an observation of
      # motion, so nothing about the filter may move
      t =
        Enum.reduce(1..4, t, fn n, t ->
          {t, [tagged], _events} =
            track(t, [det("person", mover(4), kind: "tracked")],
              at_ms: 2_000 + n * 500,
              observed_at: at(2_000 + n * 500)
            )

          assert tagged.object_id == id
          t
        end)

      assert filter(t, id) == held
    end

    test "a suspension is stitched against the last observed box, not the coasted one" do
      {t, id} = walked()

      {t, [], []} = track(t, [], at_ms: 2_500, observed_at: at(2_500))
      {t, [], []} = track(t, [], at_ms: 3_000, observed_at: at(3_000))
      {t, [], _info} = Tracker.suspend(t, 128, 3_000)

      # where the coast had reached — over half a box past the last sighting,
      # and the box a matcher that stitched against predictions would have
      # taken the identity for
      coasted = mover(7)
      assert Tracker.iou(mover(4), coasted) == 0.0

      {minted, [tagged], events} =
        track(t, [det("person", coasted)], epoch: "epoch_two", at_ms: 3_500)

      assert ids(events, :adopted) == []
      assert [{:started, %Track{object_id: other}}] = events
      assert tagged.object_id == other
      refute other == id
      # still waiting out its window, which is what "not adopted" means here
      assert [%Track{object_id: ^id}] = Tracker.suspended_tracks(minted)

      # the same suspension, offered the box it was last actually seen at
      {adopted, [tagged], events} =
        track(t, [det("person", mover(4))], epoch: "epoch_two", at_ms: 3_500)

      assert tagged.object_id == id
      assert ids(events, :adopted) == [id]
      assert ids(events, :started) == []
      assert Tracker.suspended_count(adopted) == 0
    end
  end

  describe "the low-confidence stage" do
    @floor %{"default" => 0.5}
    @below 0.3

    test "a below-floor detection that matches nothing mints no track" do
      {t, tagged, events} =
        track(Tracker.new(), [det("person", [0.1, 0.1, 0.2, 0.4], score: @below)],
          min_score: @floor
        )

      assert tagged == []
      assert events == []
      assert Tracker.live_tracks(t) == []
    end

    test "a per-label floor decides the stage, and a label without one falls back" do
      dets = [
        det("car", [0.1, 0.1, 0.2, 0.2], score: @below),
        det("person", [0.6, 0.6, 0.2, 0.2], score: @below)
      ]

      # the car's own floor admits 0.3, the person falls back to "default"
      {t, tagged, _events} =
        track(Tracker.new(), dets, min_score: %{"default" => 0.5, "car" => 0.2})

      assert [%{label: "car"}] = tagged
      assert [%Track{label: "car"}] = Tracker.live_tracks(t)
    end

    test "a below-floor detection does not adopt a suspended track" do
      box = [0.0, 0.0, 0.4, 0.4]
      {t, id} = parked(box)
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      {t, tagged, events} =
        track(t, [det("person", box, score: @below)],
          epoch: "epoch_two",
          at_ms: 11_000,
          min_score: @floor
        )

      assert tagged == []
      assert events == []
      assert Tracker.live_tracks(t) == []
      assert [%Track{object_id: ^id}] = Tracker.suspended_tracks(t)

      # and the identity is still there to be resumed by a real detection
      {_t, [tagged], events} =
        track(t, [det("person", box)], epoch: "epoch_two", at_ms: 11_500, min_score: @floor)

      assert tagged.object_id == id
      assert ids(events, :adopted) == [id]
    end

    test "a below-floor detection updates the live track it matches, without moving best_score" do
      box = [0.3, 0.3, 0.2, 0.2]

      {t, [%{object_id: id}], _started} =
        track(Tracker.new(), [det("person", box)], min_score: @floor)

      {t, [tagged], events} =
        track(t, [det("person", box, score: @below)],
          at_ms: 500,
          observed_at: at(500),
          min_score: @floor
        )

      assert tagged.object_id == id
      assert ids(events, :started) == []

      # a real match, so liveness is refreshed and the weak score is the
      # track's current one — but `best_score` is a running maximum, so the
      # broadcast throttle's improvement bypass cannot be tripped by noise
      assert [%Track{object_id: ^id, score: @below, best_score: 0.9} = live] =
               Tracker.live_tracks(t)

      assert live.last_seen_at == at(500)
    end

    # `@max_unseen` is 3_000 and `@stationary_unseen_factor` is 5, so a
    # stationary track's grace runs from 13_000 to 25_000 and 14_000 is inside
    # it — the same timing the "stationary grace" describe uses. Dyadic boxes,
    # so both overlaps are exact: equal boxes offset by `d` sit at
    # `(w - d) / (w + d)`, which is 0.6 at an eighth of the frame and 7/9 at a
    # sixteenth.
    test "stage two matches a track in grace at @stationary_match_iou, not the base threshold" do
      parked_box = [0.25, 0.25, 0.5, 0.25]
      mid = [0.375, 0.25, 0.5, 0.25]
      near = [0.3125, 0.25, 0.5, 0.25]

      assert Tracker.iou(parked_box, mid) == 0.6
      assert_in_delta Tracker.iou(parked_box, near), 7 / 9, 0.001

      {parked, id} = parked(parked_box, "car")

      # 0.6 clears the base `@iou_threshold` many times over, so a stage two
      # that read the base threshold would take this box and refresh the track.
      # It reads `match_threshold/2` like stage one, so the grace refuses it —
      # and being below the floor, the refusal is a drop and nothing else: no
      # mint, and no mark, because suppression never sees it.
      {refused, tagged, events} =
        track(parked, [det("car", mid, score: @below)],
          at_ms: 14_000,
          observed_at: at(14_000),
          min_score: @floor
        )

      assert tagged == []
      assert events == []
      assert [%Track{object_id: ^id, last_seen_at: unmoved}] = Tracker.live_tracks(refused)
      assert unmoved == at(10_000)

      # and the same weak box at an overlap the grace does accept is a real
      # match: the identity is retained, liveness is refreshed, and the
      # sub-floor score does not touch `best_score`
      {matched, [tagged], events} =
        track(parked, [det("car", near, score: @below)],
          at_ms: 14_000,
          observed_at: at(14_000),
          min_score: @floor
        )

      assert tagged.object_id == id
      assert ids(events, :started) == []

      assert [%Track{object_id: ^id, bbox: ^near, best_score: 0.9} = live] =
               Tracker.live_tracks(matched)

      assert live.last_seen_at == at(14_000)
    end

    test "a below-floor leftover does not mark a track seen, where an above-floor one does" do
      # the band the refusal case lives in: over `@duplicate_suppression_iou`
      # (0.4) and under `@stationary_match_iou` (0.7), so the parked track in
      # its extended grace refuses the box either way
      assert_in_delta Tracker.iou(@parked_car, @car_drift), 0.5, 0.001

      {parked, id} = parked(@parked_car, "car")

      {weak, [], []} =
        track(parked, [det("car", @car_drift, score: @below)],
          at_ms: 14_000,
          observed_at: at(14_000),
          min_score: @floor
        )

      # dropped before suppression ever weighed it, so nothing about the track
      # moved: sub-floor noise beside a live track may not hold it alive
      assert [%Track{object_id: ^id, last_seen_at: last_seen}] = Tracker.live_tracks(weak)
      assert last_seen == at(10_000)

      # the same box above the floor is suppression's business, and a
      # suppression is a sign of life
      {strong, [], []} =
        track(parked, [det("car", @car_drift)],
          at_ms: 14_000,
          observed_at: at(14_000),
          min_score: @floor
        )

      assert [%Track{object_id: ^id, last_seen_at: at_14}] = Tracker.live_tracks(strong)
      assert at_14 == at(14_000)
    end
  end
end
