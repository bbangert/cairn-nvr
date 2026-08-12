defmodule Cairn.TrackerTest do
  use ExUnit.Case, async: true

  import Cairn.TrackAssertions
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Cairn.Observation
  alias Cairn.ObservationClock
  alias Cairn.PluginProtocol
  alias Cairn.Track
  alias Cairn.Tracker
  alias Cairn.Tracker.Bbd
  alias Membrane.MOTTracker.Kalman

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
  # the same twin, nudged on both axes to IoU 0.9 — the shape of the live
  # cold-start failure, where the two boxes of one car arrived before either had
  # a track and both minted. Separate from @car_double so that the twin-mint
  # tests and the leftover-suppression tests cannot be made to pass by one
  # fixture's arithmetic
  @car_twin [0.4048, 0.5032, 0.18, 0.12]
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
    object = %{
      label: label,
      bbox: bbox,
      score: Keyword.get(opts, :score, 0.9),
      track_id: Keyword.get(opts, :track_id),
      observation_kind: Keyword.get(opts, :kind, "detected")
    }

    # Only-when-present, as `Cairn.PluginProtocol.validate_object/1` builds
    # them: an embedder-less object has no :embedding key at all.
    case Keyword.get(opts, :embedding) do
      nil -> object
      feature -> Map.put(object, :embedding, feature)
    end
  end

  # `observed_at` defaults to the wall instant `at_ms` names, which is what the
  # ports produce: one clock advances the tracking decisions and the other dates
  # the same observation for a human. A test that needs them apart passes both.
  defp ctx(opts) do
    at_ms = Keyword.get(opts, :at_ms, 0)

    context = %{
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

    # Each flag key is absent unless a test asks for it, so that everything here
    # bar the flag blocks runs against the context a caller which has never
    # heard of any flag hands the tracker — and so that "off" and "absent"
    # are distinguishable things a test can compare. For `twin_mint` that
    # distinction is load-bearing in the other direction: absent means ON.
    Enum.reduce([:bbd, :oru, :ocr, :twin_mint, :reid], context, fn key, context ->
      case Keyword.fetch(opts, key) do
        {:ok, value} -> Map.put(context, key, value)
        :error -> context
      end
    end)
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

    # The same detector, one batch earlier: before either box has a track, the
    # rule above has nothing to weigh them against, so both mint and the object
    # is born with two identities. The score order is the live failure's, and
    # deliberately the reverse of the batch order — the twin the tracker keeps
    # is the better-scored one and not the first one.
    test "an object first detected as two boxes mints once, not twice" do
      assert_in_delta Tracker.iou(@parked_car, @car_twin), 0.9, 0.001

      {t, tagged, events} =
        track(Tracker.new(), [
          det("car", @parked_car, score: 0.53),
          det("car", @car_twin, score: 0.82)
        ])

      # the weaker box is absent from `tagged` exactly as a suppressed leftover
      # is: there is no identity to draw it under
      assert [%{bbox: @car_twin, object_id: id, score: 0.82}] = tagged
      assert [{:started, %Track{object_id: ^id, bbox: @car_twin, score: 0.82}}] = events
      assert [%Track{object_id: ^id, best_score: 0.82}] = Tracker.live_tracks(t)
    end

    # Why the drop has to land on the first batch: a twinned pair sustains
    # itself. Greedy would match one box to each of the two tracks, a matched
    # box is never a leftover, and suppression would never be offered either of
    # them again. With one track, the design intends the second box to be an
    # ordinary leftover on every later batch, suppressed against the live
    # track by the rule above — though from out here the two passes produce
    # the same observable (one track, one tagged box, no mint), so what this
    # test pins is the outcome across the run, with the first batch's single
    # `:started` as the only assertion the twin pass alone can satisfy. That
    # black-box reach is accepted; a white-box probe of which pass dropped a
    # given box would couple the test to the pipeline's internals.
    test "the twinned pair the first-batch drop prevents never re-forms" do
      {t, [%{object_id: id}], _events} =
        track(Tracker.new(), [
          det("car", @parked_car, score: 0.53),
          det("car", @car_twin, score: 0.82)
        ])

      {t, started} =
        Enum.reduce(1..5, {t, []}, fn n, {t, started} ->
          ms = n * 1_000

          {t, tagged, events} =
            track(
              t,
              [det("car", @parked_car, score: 0.53), det("car", @car_twin, score: 0.82)],
              at_ms: ms,
              observed_at: at(ms)
            )

          # one box tagged per batch, and it is the one the track matched
          assert [%{object_id: ^id, bbox: @car_twin}] = tagged
          {t, started ++ ids(events, :started)}
        end)

      assert started == []
      assert [%Track{object_id: ^id, bbox: @car_twin}] = Tracker.live_tracks(t)
    end

    # `Stage.TwinMint` runs inside `assign/3`, before `apply_assignments/5`
    # ever asks `make_room/3` for space, so the dropped twin is a `:drop` in
    # `assignments` before eviction is even considered — it never competes for a
    # slot. Correct by reading the two passes side by side, but nothing pinned
    # it: a regression that let the dropped twin reach `make_room/3` would pay
    # for two evictions on this scenario instead of one, and nothing here would
    # have failed.
    test "a new twin pair at the live-track cap pays for at most one eviction" do
      capped = fn opts -> Keyword.put(opts, :max_live_tracks, 2) end

      {t, [a], _} = track(Tracker.new(), [det("person", [0.0, 0.0, 0.05, 0.05])], capped.([]))
      {t, [b], _} = track(t, [det("person", [0.9, 0.9, 0.05, 0.05])], capped.(at_ms: 100))

      {{t, tagged, events}, log} =
        with_log(fn ->
          track(
            t,
            [det("car", @parked_car, score: 0.53), det("car", @car_twin, score: 0.82)],
            capped.(at_ms: 200)
          )
        end)

      assert log =~ "live-track cap"

      # one mint, one eviction: the dropped twin (@parked_car, the lower
      # score) is absent from `tagged` as a leftover, not as a second eviction
      assert [%{bbox: @car_twin, object_id: id, score: 0.82}] = tagged

      assert [
               {:ended, %Track{object_id: evicted_id, end_reason: :evicted} = final},
               {:started, %Track{object_id: ^id, bbox: @car_twin}}
             ] = events

      # the cap's own LRU choice, not the twin drop: `a` is the least
      # recently seen of the two pre-existing tracks
      assert evicted_id == a.object_id
      assert_self_contained(final)

      assert Enum.map(Tracker.live_tracks(t), & &1.object_id) |> Enum.sort() ==
               Enum.sort([b.object_id, id])

      # non-vacuity: the same cap pressure with the second box moved out of
      # the twin band (IoU 1/3, under @duplicate_suppression_iou) mints both
      # and evicts both, so the single eviction above is the twin drop's
      # doing and not some other reason a second mint came free
      {t2, [a2], _} = track(Tracker.new(), [det("person", [0.0, 0.0, 0.05, 0.05])], capped.([]))
      {t2, [b2], _} = track(t2, [det("person", [0.9, 0.9, 0.05, 0.05])], capped.(at_ms: 100))

      {t2, tagged2, events2} =
        track(
          t2,
          [det("car", @parked_car, score: 0.53), det("car", @car_neighbour, score: 0.82)],
          capped.(at_ms: 200)
        )

      assert length(tagged2) == 2
      assert length(ids(events2, :started)) == 2

      evicted_ids2 =
        for {:ended, %Track{object_id: evicted_id, end_reason: :evicted}} <- events2,
            do: evicted_id

      assert Enum.sort(evicted_ids2) == Enum.sort([a2.object_id, b2.object_id])
      assert length(Tracker.live_tracks(t2)) == 2
    end

    # The mint side of the same threshold the refusal tests pin: two objects
    # standing next to each other are not a twin, and neither has a track to be
    # judged against, so nothing may collapse them.
    test "two same-label boxes below the threshold both mint on the first batch" do
      assert_in_delta Tracker.iou(@parked_car, @car_neighbour), 1 / 3, 0.001

      {t, tagged, events} =
        track(Tracker.new(), [
          det("car", @parked_car, score: 0.53),
          det("car", @car_neighbour, score: 0.82)
        ])

      assert [%{bbox: @parked_car, object_id: first}, %{bbox: @car_neighbour, object_id: second}] =
               tagged

      refute first == second
      assert Enum.sort(ids(events, :started)) == Enum.sort([first, second])
      assert length(Tracker.live_tracks(t)) == 2
    end

    # The label gate, on the mint side: a person standing where a car is is two
    # objects however much their boxes overlap, and the tracker has no track for
    # either of them to prefer.
    test "two overlapping boxes of different labels both mint on the first batch" do
      assert Tracker.iou(@parked_car, @car_twin) >= 0.4

      {t, tagged, events} =
        track(Tracker.new(), [det("car", @parked_car), det("person", @car_twin)])

      assert [%{label: "car", object_id: car}, %{label: "person", object_id: person}] = tagged
      refute car == person
      assert Enum.sort(ids(events, :started)) == Enum.sort([car, person])
      assert length(Tracker.live_tracks(t)) == 2
    end

    # The same branch as the cold-start test — any object's own first batch is
    # the hole, because what suppression needs is a track for *this* object and
    # a scene full of other tracks is no help. What this adds over that test is
    # the bookkeeping: the twin pair sits at non-zero batch indices beside a
    # box that matches normally, so the pass has to key on track-existence and
    # carry the right indices, not merely handle an otherwise-empty batch.
    test "an object arriving mid-stream as two boxes mints once" do
      {t, walker_id} = parked(@walker, "person")

      {t, tagged, events} =
        track(
          t,
          [
            det("person", @walker),
            det("car", @parked_car, score: 0.53),
            det("car", @car_twin, score: 0.82)
          ],
          at_ms: 11_000,
          observed_at: at(11_000)
        )

      assert [%{object_id: ^walker_id}, %{bbox: @car_twin, object_id: car_id}] = tagged
      assert ids(events, :started) == [car_id]
      assert length(Tracker.live_tracks(t)) == 2
    end

    # The ordering rationale, from the one side that can be observed: a box that
    # can still do something other than mint is not a twin candidate at all.
    # `adopt/4` runs first, so the exact box resumes the identity even though
    # the twin rule alone would have dropped it for the better-scored one — and
    # it is that better-scored box which is left over and suppressed.
    test "a box that can adopt a suspension is not dropped as the weaker twin" do
      {t, id} = parked(@parked_car, "car")
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      {t, tagged, events} =
        track(t, [det("car", @parked_car, score: 0.53), det("car", @car_twin, score: 0.82)],
          epoch: "epoch_two",
          at_ms: 10_300
        )

      # the identity resumed on the weaker box, and no second identity was made
      assert [%{object_id: ^id, bbox: @parked_car, score: 0.53}] = tagged
      assert [{:updated, %Track{object_id: ^id}}, {:adopted, %Track{object_id: ^id}}] = events
      assert ids(events, :started) == []
      assert [%Track{object_id: ^id}] = Tracker.live_tracks(t)
      assert Tracker.suspended_tracks(t) == []
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

  # The two candidates straddle the detection rather than sitting on it, which
  # is the only way a batch gets two same-label tracks this close: two boxes
  # one object's width apart mint two identities, and two boxes on top of each
  # other are that object's NMS twin and mint one (see "duplicate suppression").
  # The dyadic coordinates are the refusing-tracks tie test's, and for the same
  # reason — an exact tie has to survive being computed two ways. Each track is
  # detected at its own box twice, so each one's filter has seen nothing but
  # zero innovation and predicts exactly the box it stores: the two overlaps
  # greedy sorts are the two this test compares.
  test "an exact IoU tie is broken deterministically, not by map order" do
    left = [0.125, 0.25, 0.3125, 0.125]
    drift = [0.25, 0.25, 0.3125, 0.125]
    right = [0.375, 0.25, 0.3125, 0.125]

    assert Tracker.iou(left, drift) === Tracker.iou(right, drift)
    # and not with each other, or one would suppress the other's detections
    assert_in_delta Tracker.iou(left, right), 0.111, 0.001

    {t, [a, b], _} = track(Tracker.new(), [det("person", left), det("person", right)])
    refute a.object_id == b.object_id

    {t, [_, _], _} = track(t, [det("person", left), det("person", right)], at_ms: 100)

    # both candidates overlap identically; only the total sort key separates them
    {_t, [c], _} = track(t, [det("person", drift)], at_ms: 200)
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
    # and a re-seeded filter deliberately does not (see the two shifted
    # adoption tests, one per `tracking.oru` state)
    @shift_05 [0.05, 0.0, 0.4, 0.4]
    # IoU 0.905 with @box, 0.379 with @shift_2
    @shift_02 [0.02, 0.0, 0.4, 0.4]

    # The outage the `tracking.oru` adoptions below are measured across: 8 s
    # past the last match `parked/1` leaves at 10_000, so the adopting batch
    # lands at 18_000. Inside `Cairn.Tracker.Stage.Oru`'s replay window
    # (`@oru_min_gap_ms` 1_000 to `@oru_max_gap_ms` 10_000) and well inside
    # the minute a suspension stays
    # adoptable for, which are two different bounds and only one of them is
    # about the filter.
    @outage_ms 8_000
    @adopting_ms 10_000 + @outage_ms
    # What a replayed displacement is allowed before it reads as motion:
    # `@stationary_velocity_floor` (a tenth of the box's height) per
    # `stationary_after_ms`, scaled to the outage's own duration. The two
    # shifts above straddle it — 0.05 over, 0.02 under — which is the whole of
    # why one clears the flag and the other does not.
    @replayed_allowance 0.1 * 0.4 * @outage_ms / @stationary_after

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
      # replaced. `tracking.oru` is where the lost evidence comes back —
      # this context carries no such key, so what is pinned here is the
      # default, and the twin below is the same outage with the flag on.
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

    # A suspended track was cut at 10_000 and adopted at `@adopting_ms`, with
    # `opts` on the adopting batch alone — one fixture for every replayed
    # adoption below, so the outage they all share is built in one place.
    defp outage(box, opts) do
      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      {t, [tagged], events} =
        track(t, [det("person", box)], [epoch: "epoch_two", at_ms: @adopting_ms] ++ opts)

      assert tagged.object_id == id
      assert ids(events, :adopted) == [id]

      {t, id, tagged, events}
    end

    test "with the flag on an adoption that shifted during the outage resumes moving" do
      # the same fixture as the test above with `tracking.oru` on and the
      # outage stretched into the replay window: the shift is 0.05 against an
      # allowance of `@replayed_allowance`, so what the replay measures across
      # the cut is a displacement the live floor would have failed
      assert Enum.at(@shift_05, 0) - Enum.at(@box, 0) > @replayed_allowance

      {t, id, tagged, events} = outage(@shift_05, oru: true)

      # the flag goes, and goes with its event — a `became_stationary` closed
      # by no `started_moving` is a run `CairnWeb.TrackMoments` renders as
      # still open, so a silent clearing would misreport the pre-cut run
      refute tagged.stationary
      assert ids(events, :started_moving) == [id]

      assert [%Track{object_id: ^id, stationary: false, stationary_since: nil}] =
               Tracker.live_tracks(t)

      # and the filter carries the outage's own motion rather than the zero
      # velocity a re-seed would have left: rightwards, at the pace 0.05 over
      # the 16 steps `@outage_ms` is worth, held to the assertion's ±0.0002
      # (0.003047 measured against 0.003125) — short of exact because the
      # replay's virtual points are updates like any other and the filter
      # still smooths towards them
      {vx, vy} = Kalman.velocity(filter(t, id))
      assert vx > 0
      assert_in_delta vx, 0.05 / 16, 0.0002
      assert_in_delta vy, 0.0, 1.0e-9

      # cleared, not condemned: the ordinary settle window re-earns the flag
      # from the still run the adoption started, exactly one
      # `stationary_after_ms` on and not a batch sooner
      {t, seen} =
        Enum.reduce(1..10, {t, []}, fn n, {t, seen} ->
          ms = @adopting_ms + n * 1_000

          {t, [tagged], events} =
            track(t, [det("person", @shift_05)], epoch: "epoch_two", at_ms: ms)

          assert tagged.stationary == ms >= @adopting_ms + @stationary_after
          {t, seen ++ ids(events, :became_stationary)}
        end)

      assert seen == [id]

      assert [%Track{object_id: ^id, stationary: true, stationary_since: since}] =
               Tracker.live_tracks(t)

      # the new run's own instant, and nothing left over from the old one
      assert since == at(@adopting_ms + @stationary_after)
    end

    test "with the flag on an adoption that came back where it was stays stationary" do
      # the control: 0.02 across the same outage is under the same allowance,
      # which is the live rule's own answer for a box drifting that slowly
      assert Enum.at(@shift_02, 0) - Enum.at(@box, 0) < @replayed_allowance

      {t, id, tagged, events} = outage(@shift_02, oru: true)

      assert tagged.stationary
      assert ids(events, :started_moving) == []

      # the filter is rebuilt either way — that is not what the flag decides
      # here — and it reads a fifth of the shifted case's pace
      assert_in_delta elem(Kalman.velocity(filter(t, id)), 0), 0.02 / 16, 0.0002

      # no flap on the adopting batch and none after it, and the settle window
      # never re-armed: the instant is still the pre-cut one
      {t, seen} =
        Enum.reduce(1..10, {t, []}, fn n, {t, seen} ->
          {t, [tagged], events} =
            track(t, [det("person", @shift_02)],
              epoch: "epoch_two",
              at_ms: @adopting_ms + n * 1_000
            )

          assert tagged.stationary
          {t, seen ++ events}
        end)

      assert ids(seen, :started_moving) == []
      assert ids(seen, :became_stationary) == []

      assert [%Track{object_id: ^id, stationary: true, stationary_since: since}] =
               Tracker.live_tracks(t)

      assert since == at(10_000)
    end

    test "an adoption gap past the replay window re-seeds the filter, flag or no flag" do
      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      # 20_500 ms past the last match: outside `Stage.Oru`'s `@oru_max_gap_ms`
      # (10_000) and
      # still inside the minute the suspension is adoptable for, which is the
      # band most of the adoption window sits in
      adopt = fn opts ->
        {t, [tagged], events} =
          track(t, [det("person", @shift_05)], [epoch: "epoch_two", at_ms: 30_500] ++ opts)

        assert tagged.object_id == id
        {t, tagged, events}
      end

      {on, on_tagged, on_events} = adopt.(oru: true)
      {off, off_tagged, off_events} = adopt.(oru: false)

      assert on_tagged == off_tagged
      assert on_events == off_events
      assert on.objects == off.objects

      # not merely equal to the flag-off run but equal to a bare seed from the
      # adopting box: `revive/3`'s nil reaches `advance/3`, which inits, and an
      # init has no velocity to assert anything with
      assert filter(on, id) == Kalman.init(@shift_05)
      assert Kalman.velocity(filter(on, id)) == {0.0, 0.0}

      # and the flag survives the shift the in-window run clears it on, since
      # nothing measured this gap
      assert on_tagged.stationary
      assert ids(on_events, :started_moving) == []
    end

    test "a predicted box may not resume an identity with the flag on either" do
      {t, id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      # the `detected?` gate is upstream of everything `tracking.oru` touches —
      # `adopt/4` refuses the box before any filter question is asked — so the
      # flag cannot talk the plugin's extrapolation into an adoption
      {predicted, [tagged], events} =
        track(t, [det("person", @box, kind: "tracked")],
          epoch: "epoch_two",
          at_ms: @adopting_ms,
          oru: true
        )

      assert [{:started, %Track{object_id: other}}] = events
      assert tagged.object_id == other
      refute other == id
      assert [%Track{object_id: ^id}] = Tracker.suspended_tracks(predicted)

      # withheld rather than lost, as with the flag off: the same box detected
      # resumes the identity
      {_detected, id, tagged, _events} = outage(@box, oru: true)
      assert tagged.object_id == id
    end

    test "with the flag off an adoption is what it is without the key" do
      {t, _id} = parked(@box)
      {t, [], _info} = Tracker.suspend(t, 128, 10_000)

      adopt = fn box, opts ->
        track(t, [det("person", box)], [epoch: "epoch_two", at_ms: @adopting_ms] ++ opts)
      end

      # both sides of the allowance, since they are two different outcomes with
      # the flag on and must be the same one without it
      for box <- [@shift_02, @shift_05] do
        assert adopt.(box, oru: false) == adopt.(box, [])

        # non-vacuity: the flag on does change this very adoption, so what the
        # equality above pins is the flag's absence and not an inert fixture
        refute adopt.(box, oru: true) == adopt.(box, oru: false)
      end
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

  # A far slower walker than @mover_step, at a fiftieth of the frame per batch.
  # Slow is what the gap-replay tests need: an object that turns back during a
  # gap has to end up somewhere its own coasted prediction still overlaps, or
  # nothing matches and there is no filter to compare. Every box is 0.1 x 0.1
  # and in frame throughout.
  @creep_step 0.01
  defp creeper(n), do: [0.30 + n * @creep_step, 0.5, 0.1, 0.1]

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

  # Every batch of `batches` — each a `{context opts, objects}` pair — folded
  # from a fresh tracker with `opts` on all of them, keeping every event of the
  # run rather than the last batch's alone.
  defp replay(batches, opts) do
    Enum.reduce(batches, {Tracker.new(), [], []}, fn {batch_opts, dets}, {t, _tagged, seen} ->
      {t, tagged, events} = track(t, dets, batch_opts ++ opts)
      {t, tagged, seen ++ events}
    end)
  end

  # A `track/3` result with every ULID replaced by the order it was started in.
  # An identity is random by construction, so it is the one thing two runs of
  # the same scenario differ in whatever the scenario does, and rewriting it is
  # what makes "identical behaviour" something a test can assert at all. Every
  # id in a `replay/2` result is covered: the run starts from `Tracker.new/0`,
  # so nothing in it was minted anywhere else.
  defp canonical({_tracker, _tagged, events} = result) do
    minted = events |> ids(:started) |> Enum.with_index() |> Map.new()
    substitute(result, minted)
  end

  defp substitute(%module{} = value, mapping),
    do: value |> Map.from_struct() |> substitute(mapping) |> then(&struct(module, &1))

  defp substitute(map, mapping) when is_map(map),
    do: Map.new(map, fn {k, v} -> {substitute(k, mapping), substitute(v, mapping)} end)

  defp substitute(list, mapping) when is_list(list), do: Enum.map(list, &substitute(&1, mapping))

  defp substitute(tuple, mapping) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> substitute(mapping) |> List.to_tuple()

  defp substitute(binary, mapping) when is_binary(binary), do: Map.get(mapping, binary, binary)

  defp substitute(other, _mapping), do: other

  # What association does, spread over five runs, each carrying what it is there
  # to exercise: `started`, the tracks the whole run mints; `dropped`, how many
  # of the *last* batch's detections never reached `tagged`, which is one
  # `:drop` each; and `live`, every surviving track's label and box, sorted.
  # Which box a track ends on is what says which branch took it — a count of
  # mints alone is satisfied by any run that mints the same number for the wrong
  # reasons.
  defp flag_off_scenarios do
    parked_box = [0.0, 0.0, 0.4, 0.4]
    passer = [0.2, 0.0, 0.4, 0.4]
    elsewhere = [0.05, 0.05, 0.18, 0.12]

    [
      # The last batch is all three at once: @parked_car takes the car track on
      # its own overlap, @car_double is then left over and sits at 0.78 to that
      # track's stored box, so suppression drops it, and @car_neighbour is left
      # over at 1/3 — under @duplicate_suppression_iou — so it mints beside it
      # instead. No floor is set anywhere in this run, which makes suppression
      # the only thing in it that can produce a `:drop` at all.
      {"a mint, a match and a duplicate-suppressed leftover",
       [
         started: 3,
         dropped: 1,
         live: [{"car", @parked_car}, {"car", @car_neighbour}, {"person", @walker_step}]
       ],
       [
         {[], [det("person", @walker), det("car", @parked_car)]},
         {[at_ms: 500], [det("person", @walker_step), det("car", @parked_car)]},
         {[at_ms: 1_000],
          [
            det("person", @walker_step),
            det("car", @parked_car),
            det("car", @car_double),
            det("car", @car_neighbour)
          ]}
       ]},
      # 1_500 ms with no batch in it and then a box two and a half of its own
      # widths on: the track's stored box and the filter's prediction both
      # overlap it at exactly zero, so the walker mints a second identity and
      # the first is left frozen where it was last seen. That loss is what the
      # flag exists to undo; the headline test below is the same loss with it on.
      {"a coast wider than the box",
       [started: 2, dropped: 0, live: [{"person", mover(2)}, {"person", mover(7)}]],
       [
         {[], [det("person", mover(0))]},
         {[at_ms: 500], [det("person", mover(1))]},
         {[at_ms: 1_000], [det("person", mover(2))]},
         {[at_ms: 2_500], [det("person", mover(7))]}
       ]},
      # The parked track is stationary and unseen past `max_unseen_ms`, so it
      # admits only at @stationary_match_iou. The passer-by overlaps it by 1/3,
      # which clears neither that nor @duplicate_suppression_iou, so it is
      # refused a match and refused a drop, and mints beside the track it walked
      # past rather than inheriting it.
      {"a passer-by in the grace",
       [started: 2, dropped: 0, live: [{"person", parked_box}, {"person", passer}]],
       for(n <- 0..10, do: {[at_ms: n * 1_000], [det("person", parked_box)]}) ++
         [{[at_ms: 14_000], [det("person", passer)]}]},
      # Three batches with nothing in them and then a box the coast is still
      # near enough to match: the one shape in this list that opens an unmatched
      # gap a re-detection closes, which is the only thing `tracking.oru` has
      # anything to say about. The object turned back during the gap, so what
      # the filter comes out believing is not what it went in believing —
      # with either flag off, as here, the coasted heading is merely corrected.
      {"a coast the identity survives", [started: 1, dropped: 0, live: [{"person", creeper(1)}]],
       for(n <- 0..4, do: {[at_ms: n * @batch_ms], [det("person", creeper(n))]}) ++
         for(ms <- 2_500..3_500//@batch_ms, do: {[at_ms: ms], []}) ++
         [{[at_ms: 4_000], [det("person", creeper(1))]}]},
      # Both halves of the stage. @car_double and @car_neighbour are under the
      # floor and match the car track anyway, which is why it ends on
      # @car_neighbour — a box no mint could ever have been made for. The
      # `elsewhere` box is under the floor with no free car track left to take,
      # so stage two spends it: the last batch's one drop, minting nothing and
      # marking nothing seen.
      {"the low-confidence stage",
       [started: 2, dropped: 1, live: [{"car", @car_neighbour}, {"person", @walker}]],
       [
         {[min_score: @floor], [det("car", @parked_car)]},
         {[at_ms: 500, min_score: @floor], [det("car", @car_double, score: @below)]},
         {[at_ms: 1_000, min_score: @floor],
          [
            det("car", @car_neighbour, score: @below),
            det("car", elsewhere, score: @below),
            det("person", @walker)
          ]}
       ]}
    ]
  end

  describe "BBD admission" do
    test "with the flag off the tracker does exactly what it does without the key" do
      for {name, expected, batches} <- flag_off_scenarios() do
        {tracker, tagged, events} = off = replay(batches, bbd: false)
        {_opts, last_batch} = List.last(batches)

        # non-vacuity, per scenario: two runs that both did nothing compare
        # equal, so each scenario states the branches it is here for and the
        # comparison below only means anything once they have fired
        assert length(ids(events, :started)) == expected[:started], name
        assert length(last_batch) - length(tagged) == expected[:dropped], name

        assert tracker |> Tracker.live_tracks() |> Enum.map(&{&1.label, &1.bbox}) |> Enum.sort() ==
                 expected[:live],
               name

        assert canonical(off) == canonical(replay(batches, [])), name
      end
    end

    # The headline: two boxes that do not touch have an IoU of exactly zero
    # however near they are, so the gate cannot tell the track's own object
    # from anything else once the coast is longer than the box is wide.
    test "a coast the IoU gate loses the identity in is held on centre distance" do
      # longer than this whole run: the coast below is deliberately longer than
      # @max_unseen (3_000), and a track that expired mid-coast would never
      # reach the matcher this test is about
      opts = [max_unseen_ms: 30_000]

      {t, id} = walked()

      # eight batches nothing detected it in, so the filter coasts eight times
      # and predicts a ninth at match time — far enough that the prediction has
      # run clear of the walker below rather than merely drifting off it
      t =
        Enum.reduce(2_500..6_000//500, t, fn ms, t ->
          {t, [], []} = track(t, [], [at_ms: ms] ++ opts)
          t
        end)

      # the walker slowed while nothing was watching: it is short of where the
      # coast went, and a box and a half past where it was last seen, so it
      # overlaps neither — which is also what keeps suppression out of this
      resumed = mover(7)
      assert Tracker.iou(mover(4), resumed) == 0.0

      # the mint is the proof that the coast really did outrun it: the pair is
      # under the base threshold, so the IoU gate refuses it outright
      {_off, [tagged], events} =
        track(t, [det("person", resumed)], [at_ms: 6_500, bbd: false] ++ opts)

      assert [{:started, %Track{object_id: minted}}] = events
      assert tagged.object_id == minted
      refute minted == id

      {on, [tagged], events} =
        track(t, [det("person", resumed)], [at_ms: 6_500, bbd: true] ++ opts)

      assert tagged.object_id == id
      assert ids(events, :started) == []
      assert [%Track{object_id: ^id, bbox: ^resumed}] = Tracker.live_tracks(on)
    end

    # The label gate is the IoU pass's, and `Stage.Bbd` carries it unchanged:
    # centre distance is a second way to admit a comparable pair, never a way
    # around what makes two boxes comparable. It is also where the gate carries
    # the most weight — a car and a person a few tenths apart overlap at zero
    # like every other disjoint pair, which is exactly the reading distance is
    # here to rescue.
    test "a different label is not admitted on distance, however near it is" do
      opts = [max_unseen_ms: 30_000, bbd: true]

      {t, id} = walked()

      t =
        Enum.reduce(2_500..6_000//500, t, fn ms, t ->
          {t, [], []} = track(t, [], [at_ms: ms] ++ opts)
          t
        end)

      # the headline test's box, at the same instant of the same coast — a pair
      # the IoU gate refuses outright up there, so distance is the only
      # admission that could match this one either
      resumed = mover(7)
      assert Tracker.iou(mover(4), resumed) == 0.0

      {cars, [tagged], events} = track(t, [det("car", resumed)], [at_ms: 6_500] ++ opts)

      assert [{:started, %Track{object_id: minted}}] = events
      assert tagged.object_id == minted
      refute minted == id
      # and the person track was passed over rather than moved onto the car box
      assert %{bbox: unmoved} = cars.objects[id]
      assert unmoved == mover(4)

      # non-vacuity: the identical box under the track's own label does match,
      # so the label is the whole of what stood between that pair and this one
      {people, [tagged], events} = track(t, [det("person", resumed)], [at_ms: 6_500] ++ opts)

      assert tagged.object_id == id
      assert ids(events, :started) == []
      assert [%Track{object_id: ^id, bbox: ^resumed}] = Tracker.live_tracks(people)
    end

    # Concatenation and not a merge: the two lists are spent in order, so the
    # only thing a distance-admitted pair can take is what overlap left free.
    test "a BBD pair never outranks an IoU pair for the same object" do
      # a small track barely clearing the base threshold, and a large one that
      # contains the detection outright and still falls under it — a big box
      # swallowing a small one is a poor overlap and a tiny centre distance,
      # which is exactly where the two orderings disagree
      weak = [0.42, 0.50, 0.10, 0.10]
      near = [0.30, 0.30, 0.40, 0.40]
      box = [0.50, 0.50, 0.10, 0.10]

      assert_in_delta Tracker.iou(weak, box), 1 / 9, 0.001
      assert Tracker.iou(weak, box) > 0.1
      assert Tracker.iou(near, box) < 0.1

      # both tracks are one detection old, so each predicts its own box back
      # and 0.5 s is the gap this batch is matched over
      assert Bbd.distance(near, box, 0.5) < Bbd.distance(weak, box, 0.5)
      assert Bbd.admit?(Bbd.distance(near, box, 0.5))

      {t, [%{object_id: weak_id}, %{object_id: _near_id}], _events} =
        track(Tracker.new(), [det("person", weak), det("person", near)])

      {_t, [tagged], events} = track(t, [det("person", box)], at_ms: 500, bbd: true)

      assert tagged.object_id == weak_id
      assert ids(events, :started) == []
      assert ids(events, :updated) == [weak_id]

      # and the pair the concatenation buried is a real one: with the weakly
      # overlapping track out of the scene, the nearer one does take the box
      {alone, [%{object_id: id}], _events} = track(Tracker.new(), [det("person", near)])
      {_alone, [tagged], events} = track(alone, [det("person", box)], at_ms: 500, bbd: true)
      assert tagged.object_id == id
      assert ids(events, :started) == []
    end

    # A parked object's own re-detections overlap it by definition, so the only
    # thing centre distance could add here is a way for something else to
    # inherit the identity the grace exists to protect.
    test "a parked identity is not taken on distance, in the grace or out of it" do
      box = [0.0, 0.0, 0.4, 0.4]
      far = [0.5, 0.5, 0.4, 0.4]

      # non-vacuity: no overlap at all, so nothing but the exclusion is keeping
      # this box off the parked track — and it is well inside the distance gate
      assert Tracker.iou(box, far) == 0.0
      assert Bbd.admit?(Bbd.distance(box, far, 4.0))

      {parked, id} = parked(box)

      # 4_000 unseen, inside the extended grace, and 1_000 unseen, out of it:
      # what excludes the track is its stationary flag and not the grace, so
      # the answer is the same either side of it
      for at_ms <- [14_000, 11_000] do
        {t, [tagged], events} = track(parked, [det("person", far)], at_ms: at_ms, bbd: true)

        assert [{:started, %Track{object_id: other}}] = events
        assert tagged.object_id == other
        refute other == id

        # and the identity was held rather than merely withheld
        {_t, [redetected], events} =
          track(t, [det("person", box)], at_ms: at_ms + 1_000, bbd: true)

        assert redetected.object_id == id
        assert ids(events, :started) == []
      end
    end

    test "a passer-by in the grace does not take the parked identity with the flag on" do
      box = [0.0, 0.0, 0.4, 0.4]
      passer = [0.2, 0.0, 0.4, 0.4]

      # the same band as the passer-by test above — over the base threshold,
      # under @stationary_match_iou — and comfortably inside the distance gate,
      # so with the parked track excluded @stationary_match_iou is still the
      # sole thing standing between this box and the identity
      assert Tracker.iou(box, passer) > 0.1
      assert Tracker.iou(box, passer) < 0.7
      assert Bbd.admit?(Bbd.distance(box, passer, 4.0))

      {parked, id} = parked(box)

      {t, [tagged], events} = track(parked, [det("person", passer)], at_ms: 14_000, bbd: true)

      assert [{:started, %Track{object_id: passer_id}}] = events
      assert tagged.object_id == passer_id
      refute passer_id == id

      {_t, [redetected], events} = track(t, [det("person", box)], at_ms: 15_000, bbd: true)

      assert redetected.object_id == id
      assert ids(events, :started) == []
      assert ids(events, :updated) == [id]
    end

    test "stage two matches on distance too, and its leftover still mints nothing" do
      opts = [max_unseen_ms: 30_000, min_score: @floor, bbd: true]

      {t, id} = walked()

      t =
        Enum.reduce(2_500..6_000//500, t, fn ms, t ->
          {t, [], []} = track(t, [], [at_ms: ms] ++ opts)
          t
        end)

      # the same coast as the headline test, and a weak box: stage one has no
      # object at all, so the track is free when stage two runs
      resumed = mover(7)
      elsewhere = [0.05, 0.05, 0.10, 0.10]

      {stage_two, tagged, events} =
        track(
          t,
          [det("person", resumed, score: @below), det("person", elsewhere, score: @below)],
          [at_ms: 6_500] ++ opts
        )

      # the second weak box has nothing left to take — one live track, and the
      # nearer box took it — so stage two spends it, which is the whole of what
      # a below-floor leftover may do: no mint, and no mark either
      assert [%{object_id: ^id}] = tagged
      assert ids(events, :started) == []

      assert [%Track{object_id: ^id, bbox: ^resumed, best_score: 0.9}] =
               Tracker.live_tracks(stage_two)
    end

    # A matched object is consumed, and `suppress_duplicates/4` only ever sees
    # what association left over — so a box that would have been dropped as
    # somebody's duplicate is not dropped once something takes it.
    test "a BBD-matched box is consumed and never reaches duplicate suppression" do
      # a car detected where it is, and the second box a detector without NMS
      # emits for it — well above @duplicate_suppression_iou, which is what
      # makes the leftover a drop with the flag off
      assert Tracker.iou(@parked_car, @car_double) > 0.4

      # a second car, far enough that neither box overlaps its prediction at
      # all and near enough in centre distance to answer to one
      other_car = [0.60, 0.505, 0.18, 0.12]
      assert Tracker.iou(other_car, @car_double) == 0.0
      assert Tracker.iou(other_car, @parked_car) == 0.0
      assert Bbd.admit?(Bbd.distance(other_car, @car_double, 0.5))

      {t, [%{object_id: car_id}, %{object_id: other_id}], _events} =
        track(Tracker.new(), [det("car", @parked_car), det("car", other_car)])

      batch = [det("car", @parked_car), det("car", @car_double)]

      # the first box takes its own track and the second is left over, so
      # suppression weighs it against that track's stored box and drops it
      {_off, tagged, events} = track(t, batch, at_ms: 500, bbd: false)

      assert [%{object_id: ^car_id}] = tagged
      assert ids(events, :started) == []
      assert ids(events, :updated) == [car_id]

      # with the flag on nothing is left over for suppression to weigh at all
      {on, tagged, events} = track(t, batch, at_ms: 500, bbd: true)

      assert [%{object_id: ^car_id}, %{object_id: ^other_id}] = tagged
      assert ids(events, :started) == []
      assert ids(events, :updated) == [car_id, other_id]
      assert %{bbox: @car_double} = on.objects[other_id]
    end
  end

  # Longer than any run below, so nothing in them expires mid-coast: a track
  # that ended halfway through a gap never reaches the re-detection these tests
  # are about.
  @oru_opts [max_unseen_ms: 30_000]

  # Ten detected batches of the creeper from 0, so the filter has converged on
  # the creep: the tracker at 4_500 with one track on creeper(9).
  defp crept(opts) do
    Enum.reduce(0..9, {Tracker.new(), nil}, fn n, {tracker, id} ->
      {tracker, [tagged], _events} =
        track(tracker, [det("person", creeper(n))], [at_ms: n * @batch_ms] ++ opts)

      {tracker, id || tagged.object_id}
    end)
  end

  # `from_ms` through `to_ms` exclusive with nothing in any batch, which is what
  # opens an unmatched gap: every live track coasts once per step.
  defp coast(tracker, from_ms, to_ms, opts) do
    Enum.reduce(from_ms..(to_ms - @batch_ms)//@batch_ms, tracker, fn ms, tracker ->
      {tracker, [], []} = track(tracker, [], [at_ms: ms] ++ opts)
      tracker
    end)
  end

  # A track re-detected at `box`, asserting the box landed on it rather than
  # minting beside it — which is the premise of every comparison below, and the
  # one thing none of them would notice if it stopped holding.
  defp rematched({tracker, id}, box, at_ms, opts) do
    {tracker, [tagged], events} = track(tracker, [det("person", box)], [at_ms: at_ms] ++ opts)

    assert tagged.object_id == id
    assert ids(events, :started) == []

    {tracker, id, events}
  end

  # The creeper coasted from 4_500 to `at_ms`, as one tracker for both flag
  # states to branch off rather than two runs of the same steps. Nothing before
  # the closing detection can differ between them — every batch of the run
  # either matched at a gap of one batch, well under `Stage.Oru`'s
  # `@oru_min_gap_ms`, or
  # carried nothing at all — and branching is what makes the two runs share an
  # identity, so their tracks and their events compare field for field instead
  # of only through what a ULID rewrite leaves.
  defp crept_gap(at_ms) do
    {tracker, id} = crept(@oru_opts)

    {coast(tracker, 4_500 + @batch_ms, at_ms, @oru_opts), id}
  end

  # An object detected at the same box every batch from 0 to 3_000. Its filter
  # has converged on no motion at all, so its prediction sits where the box is
  # however long the stretch that follows — which is what lets one stretch be
  # tested at four lengths, and seeded against empty, without the coast walking
  # the prediction off the box that closes it. Short of `stationary_after_ms`
  # throughout, so nothing here is parked.
  @waiting [0.30, 0.50, 0.10, 0.10]
  # Three tenths of a box on: an overlap of 0.538, so what the stretch changes
  # below is never whether the pair matches.
  @resumed [0.33, 0.50, 0.10, 0.10]

  defp waited(opts) do
    Enum.reduce(0..6, {Tracker.new(), nil}, fn n, {tracker, id} ->
      {tracker, [tagged], _events} =
        track(tracker, [det("person", @waiting)], [at_ms: n * @batch_ms] ++ opts)

      {tracker, id || tagged.object_id}
    end)
  end

  # The waiting object's filter after a gap of `gap_ms` closed by @resumed.
  defp waited_gap(gap_ms, opts) do
    opts = opts ++ @oru_opts
    at_ms = 3_000 + gap_ms
    {tracker, id} = waited(opts)

    {tracker, id, _events} =
      rematched({coast(tracker, 3_000 + @batch_ms, at_ms, opts), id}, @resumed, at_ms, opts)

    filter(tracker, id)
  end

  # The same object over the same stretch of the same clock, with the plugin
  # re-reporting its box through it rather than saying nothing at all.
  defp waited_seeded(opts) do
    opts = opts ++ @oru_opts
    {tracker, id} = waited(opts)

    tracker =
      Enum.reduce(3_500..7_000//@batch_ms, tracker, fn ms, tracker ->
        {tracker, [tagged], _events} =
          track(tracker, [det("person", @waiting, kind: "tracked")], [at_ms: ms] ++ opts)

        assert tagged.object_id == id
        tracker
      end)

    {tracker, id, _events} = rematched({tracker, id}, @resumed, 7_500, opts)

    filter(tracker, id)
  end

  describe "rebuilding a filter across a gap" do
    test "with the flag off the tracker does exactly what it does without the key" do
      for {name, expected, batches} <- flag_off_scenarios() do
        {tracker, tagged, events} = off = replay(batches, oru: false)
        {_opts, last_batch} = List.last(batches)

        # non-vacuity, per scenario: two runs that both did nothing compare
        # equal, so each scenario states the branches it is here for and the
        # comparison below only means anything once they have fired
        assert length(ids(events, :started)) == expected[:started], name
        assert length(last_batch) - length(tagged) == expected[:dropped], name

        assert tracker |> Tracker.live_tracks() |> Enum.map(&{&1.label, &1.bbox}) |> Enum.sort() ==
                 expected[:live],
               name

        assert canonical(off) == canonical(replay(batches, [])), name
      end
    end

    # The headline: a coast asserts the heading the object had when it vanished,
    # and the whole of what the replay is for is that the object may not have
    # kept it.
    test "the rebuilt filter carries the gap's own motion, not the pre-gap heading" do
      # the creeper turned back during the gap: three tenths of a box to the
      # left of where it was last seen, against nine batches of rightward creep
      turned_back = creeper(6)
      assert Enum.at(turned_back, 0) < Enum.at(creeper(9), 0)

      gap = crept_gap(6_500)
      {off, id, _events} = rematched(gap, turned_back, 6_500, [oru: false] ++ @oru_opts)
      {on, ^id, _events} = rematched(gap, turned_back, 6_500, [oru: true] ++ @oru_opts)

      refute filter(on, id) == filter(off, id)

      {off_vx, _vy} = Kalman.velocity(filter(off, id))
      {on_vx, _vy} = Kalman.velocity(filter(on, id))

      # the coasted filter comes out of the gap still heading the way it went
      # in, one correction poorer: it has no account of the gap at all
      assert off_vx > 0

      # the rebuilt one has the gap's own pace instead — 0.03 to the left over
      # the four steps a 2_000 ms gap is worth, held to the assertion's ±0.002
      # (-0.0059 measured against -0.0075): a four-step replay leaves more
      # smoothing shortfall than a sixteen-step one, since the replay's virtual
      # points are updates like any other and the filter smooths towards them
      assert on_vx < 0
      assert_in_delta on_vx, -0.03 / 4, 0.002
    end

    # The mandatory one. A seeded stretch is the plugin saying the object has
    # not moved, and the filter is held across it for that reason; replaying
    # synthesized motion over one would manufacture exactly the velocity the
    # stillness rule reads to decide the object is parked.
    test "a seeded stretch is never a gap, however long it runs" do
      # eight seeded batches, 3_500 ms of them — well past `Stage.Oru`'s
      # `@oru_min_gap_ms`
      # and well inside the window — each re-reporting the last detected box
      # verbatim, which is what the plugin actually puts on the wire
      assert waited_seeded(oru: true) == waited_seeded(oru: false)

      # non-vacuity: the same span of the same clock with those batches absent
      # rather than seeded is a gap, and the flag does change that filter — so
      # what the equality above pins is the seeding and not the timing
      refute waited_gap(4_500, oru: true) == waited_gap(4_500, oru: false)
    end

    # The test above never lets a gap open at all, so it cannot see this: a
    # seed the plugin sends *after* a gap is a wire pattern the protocol makes
    # near-impossible (a seed only re-reports a box the plugin is still
    # tracking, and a stretch of silence is exactly it having stopped), but
    # `Stage.Oru`'s replay refuses one for its own reason — `detected?` — and
    # nothing
    # else in this describe closes an in-window gap on anything but a real
    # detection to prove that guard does the refusing.
    test "a seed closing an in-window gap does not replay it, only a detection does" do
      {gapped, id} =
        Enum.reduce(0..1, {Tracker.new(), nil}, fn n, {tracker, id} ->
          {tracker, [tagged], _events} =
            track(tracker, [det("person", @waiting)], [at_ms: n * @batch_ms] ++ @oru_opts)

          {tracker, id || tagged.object_id}
        end)

      last_detected_ms = 1 * @batch_ms
      close_ms = 3_000
      gapped = coast(gapped, last_detected_ms + @batch_ms, close_ms, @oru_opts)

      # non-vacuity: the gap the closing batch below sees is inside the
      # window `Stage.Oru` gates on (its `@oru_min_gap_ms` and
      # `@oru_max_gap_ms`), computed from the same clocks the fixture above
      # used rather than restated as a bare number
      gap_ms = close_ms - last_detected_ms
      assert gap_ms >= 1_000 and gap_ms <= 10_000

      # same box, same gap, same flag — only `kind` and `oru` vary per call,
      # so any difference between the four is theirs alone
      close = fn kind, opts ->
        {tracker, [tagged], _events} =
          track(
            gapped,
            [det("person", @waiting, kind: kind)],
            [at_ms: close_ms] ++ @oru_opts ++ opts
          )

        assert tagged.object_id == id
        filter(tracker, id)
      end

      # the seed: `detected?` is false, so `Stage.Oru`'s replay never reaches the gap
      # check at all — the flag cannot matter, and the filter it leaves is
      # whatever the coast above already set
      assert close.("tracked", oru: true) == close.("tracked", oru: false)

      # the same gap, closed by a real detection instead: now the flag does
      # change the filter, so `detected?` is the only thing that kept the
      # seeded run above from a refit
      refute close.("detected", oru: true) == close.("detected", oru: false)
    end

    test "gaps outside the window leave the filter exactly as the flag-off run does" do
      # one batch: under `Stage.Oru`'s `@oru_min_gap_ms`, where a coasted filter
      # is still
      # close to what it last measured
      assert waited_gap(@batch_ms, oru: true) == waited_gap(@batch_ms, oru: false)

      # and past `@oru_max_gap_ms`, where a straight line between two sightings
      # is a guess of its own
      assert waited_gap(10_500, oru: true) == waited_gap(10_500, oru: false)

      # non-vacuity, and the window's own edges: both bounds are inclusive, so
      # the two gaps just inside the pair above do rebuild
      refute waited_gap(1_000, oru: true) == waited_gap(1_000, oru: false)
      refute waited_gap(10_000, oru: true) == waited_gap(10_000, oru: false)
    end

    # A virtual observation feeds the filter and nothing else: it is not a box
    # the track was seen at, not a sign of life, and not something anything
    # downstream is told about.
    test "the replay moves the filter and no other field of the track" do
      gap = crept_gap(6_500)
      {off, id, off_events} = rematched(gap, creeper(6), 6_500, [oru: false] ++ @oru_opts)
      {on, ^id, on_events} = rematched(gap, creeper(6), 6_500, [oru: true] ++ @oru_opts)

      assert off_events == on_events

      # `still_velocity` is the one field left out, and deliberately: it is the
      # stillness rule's readout *of* the filter — the drift it averages is
      # `Kalman.velocity/1` — so a rebuilt filter is read by the very next
      # evaluation. That is the intended consequence and the moduledoc says so;
      # everything else about the track is bookkeeping the virtual points may
      # not touch, clocks and stillness run included.
      dropped = [:kalman, :still_velocity]

      assert Map.drop(on.objects[id], dropped) == Map.drop(off.objects[id], dropped)
      refute on.objects[id].still_velocity == off.objects[id].still_velocity
    end
  end

  describe "the twin-mint default" do
    # The one inverted default: an absent `twin_mint` key must gate exactly
    # as `true` — the pre-#68-preserving reading — and only an explicit
    # `false` delists the stage. Named for that intent so a refactor that
    # flips `minting_stages/1`'s default fails here by name rather than
    # incidentally across the golden suite.
    test "an absent twin_mint key means the gate is on; only false delists it" do
      twins = [
        det("car", [0.30, 0.30, 0.20, 0.40]),
        det("car", [0.32, 0.30, 0.20, 0.40], score: 0.7)
      ]

      {_t, _tagged, absent} = Tracker.track(Tracker.new(), twins, ctx(at_ms: 0))
      {_t, _tagged, on} = Tracker.track(Tracker.new(), twins, ctx(at_ms: 0, twin_mint: true))
      {_t, _tagged, off} = Tracker.track(Tracker.new(), twins, ctx(at_ms: 0, twin_mint: false))

      assert length(ids(absent, :started)) == 1
      assert length(ids(on, :started)) == 1
      assert length(ids(off, :started)) == 2
    end
  end

  describe "still?/3" do
    # The shared stillness test, public for its second caller
    # (`Cairn.Tracker.Stage.Oru`). What these pin is the doc's guarantee that
    # the floors are *rates per settle window* — a tenth of the box's height
    # (velocity) and a fifth (growth) per `stationary_after_ms` — so the same
    # drift can pass one window and fail a longer one. Bounds below are
    # computed from those ratios for an h = 0.4 box at the suite's 10_000 ms
    # settle: velocity floor 4.0e-6/ms, growth floor 8.0e-6/ms.
    defp still_box, do: det("person", [0.3, 0.3, 0.2, 0.4])

    test "the velocity floor scales with box height per settle window" do
      assert Tracker.still?({3.9e-6, 0.0, 0.0}, still_box(), ctx([]))
      refute Tracker.still?({4.1e-6, 0.0, 0.0}, still_box(), ctx([]))
    end

    test "the same drift fails a longer settle window — the floor is a rate" do
      drift = {3.9e-6, 0.0, 0.0}

      assert Tracker.still?(drift, still_box(), ctx([]))
      refute Tracker.still?(drift, still_box(), ctx(stationary_after_ms: 2 * @stationary_after))
    end

    test "velocity is judged radially, not per axis" do
      # Each axis alone is under the 4.0e-6 floor; their norm (~4.24e-6)
      # is not — a diagonal creep may not pass by splitting itself.
      assert Tracker.still?({3.0e-6, 0.0, 0.0}, still_box(), ctx([]))
      assert Tracker.still?({0.0, 3.0e-6, 0.0}, still_box(), ctx([]))
      refute Tracker.still?({3.0e-6, 3.0e-6, 0.0}, still_box(), ctx([]))
    end

    test "growth has its own floor, symmetric in sign" do
      assert Tracker.still?({0.0, 0.0, 7.9e-6}, still_box(), ctx([]))
      refute Tracker.still?({0.0, 0.0, 8.1e-6}, still_box(), ctx([]))
      refute Tracker.still?({0.0, 0.0, -8.1e-6}, still_box(), ctx([]))
    end
  end

  describe "observation-centric recovery (tracking.ocr)" do
    # The mover that pauses behind an occluder: four steady steps teach the
    # filter a rightward velocity, two unobserved batches let the prediction
    # sail on, and the object reappears exactly where it was last seen. The
    # IoU pass weighs the prediction — which has left — so without recovery
    # the reappearance is a fresh mint.
    @walk for step <- 0..6, do: {step * 500, [0.10 + step * 0.08, 0.40, 0.20, 0.20]}
    @vanished_at [0.58, 0.40, 0.20, 0.20]

    defp paused_mover(opts) do
      {tracker, tagged, _events} =
        Enum.reduce(@walk, {Tracker.new(), [], []}, fn {ms, bbox}, {tracker, _, _} ->
          track(tracker, [det("person", bbox)], Keyword.put(opts, :at_ms, ms))
        end)

      [%{object_id: id}] = tagged

      # Four empty batches: the track coasts, the prediction keeps walking —
      # ~0.08 per step by now, so by the reappearance it has left the stored
      # box entirely. Still inside `max_unseen_ms` of the last match at 3000.
      tracker =
        Enum.reduce([3_500, 4_000, 4_500, 5_000], tracker, fn ms, tracker ->
          {tracker, [], _} = track(tracker, [], Keyword.put(opts, :at_ms, ms))
          tracker
        end)

      {tracker, id}
    end

    test "flag off, the reappearance is swallowed as the coasted track's twin" do
      # Today's failure mode, pinned: the IoU pass weighs the prediction —
      # which has left — so the box at the old spot matches nothing, and
      # duplicate suppression then weighs it against the coasted track's
      # *stored* box (IoU 1.0) and drops it as an NMS twin, marking the
      # track seen. The mover that pauses behind an occluder is not merely
      # re-minted without recovery; it is invisible, while the refusal
      # keeps the coasted track alive.
      {tracker, id} = paused_mover([])

      {tracker, tagged, events} =
        track(tracker, [det("person", @vanished_at)], at_ms: 5_500)

      assert tagged == []
      assert ids(events, :started) == []
      assert ids(events, :updated) == []

      # The identity is still live — the swallowed box marked it seen.
      assert id in Enum.map(Tracker.live_tracks(tracker), & &1.object_id)
    end

    test "flag on, the last observation resumes the identity" do
      {tracker, id} = paused_mover(ocr: true)

      {_tracker, tagged, events} =
        track(tracker, [det("person", @vanished_at)], at_ms: 5_500, ocr: true)

      assert [%{object_id: ^id}] = tagged
      assert ids(events, :started) == []
      assert ids(events, :updated) == [id]
    end

    test "recovery composes with BBD: both listed, the identity still resumes" do
      # BBD's admission runs at both association points, recovery after; a
      # pair either has already spent is a no-op in the seeded reduce, so
      # listing both can only add recoveries, never fight over one. The
      # reappearance resumes the same identity with both flags on — by
      # whichever stage reached it first — and nothing double-assigns.
      {tracker, id} = paused_mover(bbd: true, ocr: true)

      {_tracker, tagged, events} =
        track(tracker, [det("person", @vanished_at)], at_ms: 5_500, bbd: true, ocr: true)

      assert [%{object_id: ^id}] = tagged
      assert ids(events, :started) == []
      assert ids(events, :updated) == [id]
    end

    test "a stationary identity is not widened by recovery" do
      # A parked person, stationary long since and unseen past the batch
      # window — the regime where `@stationary_match_iou` is the *whole*
      # admission. A same-label passer-by overlaps the parked box above the
      # recovery threshold but below that strict number. Recovery excludes
      # stationary tracks, so the box falls through to suppression and the
      # parked identity stays put.
      steps = for ms <- 0..24, do: {ms * 500, [0.60, 0.40, 0.20, 0.20]}
      {tracker, tagged, _} = feed(Tracker.new(), steps)
      [%{object_id: parked, stationary: true}] = tagged

      # IoU vs the parked box: 0.024 / 0.056 = 0.43 — above recovery's 0.4,
      # below `@stationary_match_iou`'s 0.7. Recovery excluding the parked
      # track leaves the box to duplicate suppression, whose floor is the
      # same number weighed against the same stored box: it drops as the
      # parked object's NMS twin. Were recovery to include stationary
      # tracks it would spend the pair *before* suppression weighs it —
      # the passer-by would resume the parked identity and walk off with it.
      passer_by = [0.68, 0.40, 0.20, 0.20]

      {_tracker, tagged, events} =
        track(tracker, [det("person", passer_by)], at_ms: 15_500, ocr: true)

      assert tagged == []
      assert ids(events, :started) == []
      assert ids(events, :updated) == []
    end
  end

  describe "appearance fusion (tracking.reid)" do
    defp int8_axis(index) do
      for i <- 0..3, into: <<>>, do: <<if(i == index, do: 127, else: 0)::signed-8>>
    end

    test "state rolls on detected boxes only, and only under the flag" do
      box = [0.10, 0.40, 0.20, 0.20]

      # Flag off: no key, ever — the byte-stability half of D-A4.
      {off, _, _} = track(Tracker.new(), [det("person", box, embedding: int8_axis(0))], at_ms: 0)
      [{_id, plain}] = Map.to_list(off.objects)
      refute Map.has_key?(plain, :embedding)

      # Flag on: minted with state, rolled by a detected box…
      {on, tagged, _} =
        track(Tracker.new(), [det("person", box, embedding: int8_axis(0))],
          at_ms: 0,
          reid: true
        )

      [%{object_id: id}] = tagged
      assert is_list(on.objects[id][:embedding])
      seeded_state = on.objects[id][:embedding]

      # …but a seeded (tracked) re-report moves nothing.
      {after_seed, _, _} =
        track(
          on,
          [det("person", box, kind: "tracked", embedding: int8_axis(1))],
          at_ms: 500,
          reid: true
        )

      assert after_seed.objects[id][:embedding] == seeded_state

      # A detected box does move it.
      {after_detect, _, _} =
        track(on, [det("person", box, embedding: int8_axis(1))], at_ms: 500, reid: true)

      refute after_detect.objects[id][:embedding] == seeded_state
    end

    test "a stationary track's appearance is frozen" do
      steps = for ms <- 0..24, do: {ms * 500, [0.60, 0.40, 0.20, 0.20]}

      {tracker, tagged, _} =
        Enum.reduce(steps, {Tracker.new(), [], []}, fn {ms, bbox}, {tracker, _, _} ->
          track(tracker, [det("person", bbox, embedding: int8_axis(0))],
            at_ms: ms,
            reid: true
          )
        end)

      [%{object_id: parked, stationary: true}] = tagged
      frozen = tracker.objects[parked][:embedding]
      assert is_list(frozen)

      # Something occludes the parked person; its crop arrives on the same
      # matched box. The rolling state must not absorb the occluder.
      {tracker, _, _} =
        track(tracker, [det("person", [0.60, 0.40, 0.20, 0.20], embedding: int8_axis(1))],
          at_ms: 12_600,
          reid: true
        )

      assert tracker.objects[parked][:embedding] == frozen
    end

    test "the rolling state survives suspension and rolls on after adoption" do
      box = [0.30, 0.40, 0.10, 0.20]

      {tracker, tagged, _} =
        track(Tracker.new(), [det("person", box, embedding: int8_axis(0))],
          at_ms: 0,
          reid: true
        )

      [%{object_id: id}] = tagged
      before_cut = tracker.objects[id][:embedding]
      assert is_list(before_cut)

      # A stream reset: the track suspends carrying its appearance…
      {tracker, _events, _info} = Tracker.suspend(tracker, 128, 500)
      assert tracker.objects == %{}

      # …and adoption in the new epoch revives it, state intact. Adoption
      # weighs the stitch overlap alone — a stale appearance can never veto
      # a track's own resumption.
      {tracker, tagged, events} =
        track(tracker, [det("person", box, embedding: int8_axis(1))],
          at_ms: 1_000,
          epoch: "epoch_two",
          reid: true
        )

      assert [%{object_id: ^id}] = tagged
      assert :adopted in Enum.map(events, fn {kind, _track} -> kind end)

      # The adopting detection was a real one, so the roll resumed from the
      # preserved state rather than reseeding.
      after_adopt = tracker.objects[id][:embedding]
      assert is_list(after_adopt)
      refute after_adopt == before_cut
      assert after_adopt != Cairn.Tracker.Reid.dequant(int8_axis(1))
    end

    test "the veto keeps a coasted identity from taking a stranger" do
      # The BBD-shaped fixture: a track coasts, and a same-label box appears
      # a short hop from the prediction — no overlap, inside BBD's distance
      # gate. With matching appearance the identity resumes; with clashing
      # appearance the veto refuses the pair and the stranger mints.
      mint = fn ->
        {tracker, tagged, _} =
          track(
            Tracker.new(),
            [det("person", [0.10, 0.40, 0.10, 0.20], embedding: int8_axis(0))],
            at_ms: 0,
            bbd: true,
            reid: true
          )

        [%{object_id: id}] = tagged
        {tracker, [], _} = track(tracker, [], at_ms: 500, bbd: true, reid: true)
        {tracker, id}
      end

      hop = [0.28, 0.40, 0.10, 0.20]

      {tracker, id} = mint.()

      {_tracker, tagged, _} =
        track(tracker, [det("person", hop, embedding: int8_axis(0))],
          at_ms: 1_000,
          bbd: true,
          reid: true
        )

      assert [%{object_id: ^id}] = tagged

      {tracker, id} = mint.()

      {_tracker, tagged, events} =
        track(tracker, [det("person", hop, embedding: int8_axis(1))],
          at_ms: 1_000,
          bbd: true,
          reid: true
        )

      assert [%{object_id: stranger}] = tagged
      refute stranger == id
      assert ids(events, :started) == [stranger]
    end
  end
end
