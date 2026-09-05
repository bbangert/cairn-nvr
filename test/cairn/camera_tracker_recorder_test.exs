defmodule Cairn.CameraTrackerRecorderTest do
  # A camera tracker's half of the track index: which finished tracks earn a
  # row, with which event id, and what lands on their timeline.
  #
  # DataCase, not ExUnit.Case: the rows are read back out of SQLite, and
  # starting a tracker runs checkpoint restore, which consults the event
  # index.
  use Cairn.DataCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Cairn.{CameraControl, CameraTracker, Event, EventCheckpoint, Observation, TrackerDriver}
  alias Cairn.Config.Camera
  alias Cairn.{Track, TrackRecorder, Tracks}

  @policy %{pre: 5, post: 10, max: 300, max_unseen_ms: 3_000, max_live_tracks: 128}

  setup do
    camera_id = "trkr_#{System.unique_integer([:positive])}"
    # The checkpoint owner drops a write for a camera the fleet does not name.
    Cairn.SnapshotHelpers.lend_cameras(camera_id)
    camera = %Camera{id: camera_id, rtsp_url: "rtsp://h/1", min_score: %{"default" => 0.5}}
    test_pid = self()

    rec = start_supervised!({TrackRecorder, name: nil, manual: true})

    tracker =
      start_supervised!(
        {CameraTracker,
         camera_id: camera_id,
         name: nil,
         recorder: rec,
         start_extractor: fn _camera, event ->
           pid = spawn(fn -> Process.sleep(:infinity) end)
           send(test_pid, {:extractor_started, event, pid})
           {:ok, pid}
         end,
         finalize_extractor: fn pid, event ->
           send(test_pid, {:extractor_finalized, pid, event})
         end}
      )

    Event.subscribe()
    on_exit(fn -> EventCheckpoint.delete(camera_id) end)

    %{tracker: tracker, rec: rec, camera: camera, camera_id: camera_id}
  end

  # -- helpers ----------------------------------------------------------------

  defp observe(tracker, camera, objects, opts) do
    policy = Keyword.get(opts, :policy, @policy)

    # On a healthy stream the port's `at_ms` tracks `media_ms` one for one
    # (`Cairn.ObservationClock`), so these fixtures move the two together and
    # name the number after the clock the tracker actually decides on.
    at_ms = at_ms(Keyword.get(opts, :at_ms, 1_000))

    observation = %Observation{
      epoch: Keyword.get(opts, :epoch),
      pts: 90_000,
      media_ms: at_ms,
      at_ms: at_ms,
      observed_at: Keyword.get(opts, :observed_at, DateTime.utc_now()),
      time_quality: :arrival,
      objects: objects,
      protocol: :v0
    }

    # The real seam, end to end: `TrackerDriver` runs `Membrane.MOTTracker` and
    # `Cairn.Pipeline.TrackSink` over this observation and dispatches through
    # `Cairn.Detect.Dispatch` itself, so there is no second route left to pick
    # between — every call here already goes through it.
    TrackerDriver.detections(tracker, camera, policy, observation, Keyword.take(opts, [:core]))
  end

  # The tracker decides on `at_ms`, which production derives from the host's
  # monotonic clock (`Cairn.ObservationClock`) — the same clock a stream cut is
  # stamped with and the adoption sweep measures its window from. These
  # fixtures are therefore offsets from one base captured per test process
  # rather than absolutes: batches can be spaced to the millisecond, because
  # nothing between them re-reads a clock, while still landing on the scale
  # the tracker's own defaults read.
  defp at_ms(offset), do: clock_base() + offset

  defp clock_base do
    case Process.get(:clock_base) do
      nil ->
        base = System.monotonic_time(:millisecond)
        Process.put(:clock_base, base)
        base

      base ->
        base
    end
  end

  defp object(label, score, bbox) do
    %{
      label: label,
      score: score,
      bbox: bbox,
      track_id: nil,
      observation_kind: "detected"
    }
  end

  # The plugin is predicting this box rather than detecting it: tracked, never
  # evidence (`Cairn.Observation.detected?/1`), so no event opens for it.
  defp predicted(label, score, bbox) do
    %{object(label, score, bbox) | observation_kind: "tracked"}
  end

  # Drains both mailboxes, then drives the recorder's flush by hand: every
  # assertion below is on rows in SQLite rather than on either process's state.
  defp flush(tracker, rec) do
    _ = :sys.get_state(tracker)
    send(rec, {:flush, :sys.get_state(rec).flush_token})
    _ = :sys.get_state(rec)
    :ok
  end

  # Starts a track, then ends it by unseen expiry on the observation clock —
  # the one end path a test
  # can drive without touching timers or epochs. The second observation is
  # empty and lands past `max_unseen_ms` (3 000) of the first, which is what
  # retires it.
  defp start_and_end_track(ctx, opts \\ []) do
    policy = Keyword.get(opts, :policy, @policy)
    score = Keyword.get(opts, :score, 0.9)
    label = Keyword.get(opts, :label, "person")

    observe(ctx.tracker, ctx.camera, [object(label, score, [0.1, 0.1, 0.2, 0.4])], policy: policy)

    assert_receive {:track_started, %Track{object_id: oid}}

    observe(ctx.tracker, ctx.camera, [], at_ms: 5_000.0, policy: policy)

    assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :unseen}}
    oid
  end

  defp tier(rules), do: Map.put(@policy, :track, rules)

  defp tiers(track, record),
    do: @policy |> Map.put(:track, track) |> Map.put(:record, record)

  # A stream boundary through the real seam, for a test that needs one. The
  # direct broadcast keeps the tracker's own `current_epoch` in step
  # (`stale?/2` reads it, and would otherwise drop what follows as stale), and
  # the empty buffer under the new epoch is what makes the tracker element
  # itself suspend what it was holding — the cut is buffer-driven now, not a
  # broadcast `Cairn.CameraTracker` used to react to on its own.
  defp cut_epoch(tracker, camera, at_ms_offset, reason \\ :source_lost) do
    epoch = Cairn.ULID.generate()
    send(tracker, {:stream_epoch, camera.id, :main, epoch, reason})
    _ = :sys.get_state(tracker)
    observe(tracker, camera, [], epoch: epoch, at_ms: at_ms_offset)
    epoch
  end

  # The element's adoption sweep, forced past its window regardless of when
  # the cut actually landed: `TrackerDriver.sweep/4` overwrites the cut it is
  # waiting on, so a distant `at_ms` is what used to take a `cut_clock`
  # stamped in the past to fake.
  defp sweep(tracker, camera, at_ms_offset) do
    TrackerDriver.sweep(tracker, camera, @policy, at_ms(at_ms_offset))
    _ = :sys.get_state(tracker)
  end

  # -- the gate ---------------------------------------------------------------

  describe "a track that ended while an event was open" do
    test "is recorded with the event id even though the tier excludes its label", ctx do
      # `track:` is a whitelist and lists only "car", so "person" is excluded
      # from it — and is recorded anyway, because a clip's contents have to be
      # enumerable from the clip.
      camera = %{ctx.camera | track: %{"car" => %{min_score: 0.5}}}
      ctx = %{ctx | camera: camera}

      oid = start_and_end_track(ctx, policy: tier(%{"car" => %{min_score: 0.5}}))
      assert_receive {:extractor_started, %Event{id: eid}, _pid}

      flush(ctx.tracker, ctx.rec)

      row = Tracks.get(oid)
      assert row.event_id == eid
      assert row.camera_id == ctx.camera_id
      assert row.end_reason == :unseen
      assert row.label == "person"
    end

    test "is recorded with the event id even though it scores under the tier", ctx do
      camera = %{ctx.camera | track: %{"person" => %{min_score: 0.95}}}
      ctx = %{ctx | camera: camera}

      oid = start_and_end_track(ctx, policy: tier(%{"person" => %{min_score: 0.95}}))
      assert_receive {:extractor_started, %Event{id: eid}, _pid}

      flush(ctx.tracker, ctx.rec)

      assert Tracks.get(oid).event_id == eid
    end
  end

  describe "a track that expires in the same batch that opens an event" do
    test "is gated on the tier and linked to no event", ctx do
      # A predicted ("tracked") object is never evidence, so this track exists
      # with no event ever having opened for it — and it scores well over the
      # wire floor, so the tier passes it. The assertion is therefore about the
      # linkage and nothing else.
      observe(ctx.tracker, ctx.camera, [predicted("person", 0.9, [0.0, 0.0, 0.1, 0.1])],
        at_ms: 1_000.0
      )

      assert_receive {:track_started, %Track{object_id: expiring}}
      refute_received {:event_started, _}

      # One observation, two things at once: the observation clock has jumped past
      # `max_unseen_ms` so the old track expires inside `Tracker.track/3`, and
      # the object it carries is fresh evidence that opens an event.
      observe(ctx.tracker, ctx.camera, [object("person", 0.9, [0.8, 0.8, 0.1, 0.1])],
        at_ms: 9_000.0
      )

      assert_receive {:track_ended, %Track{object_id: ^expiring, end_reason: :unseen}}
      assert_receive {:event_started, %Event{id: eid}}

      flush(ctx.tracker, ctx.rec)

      row = Tracks.get(expiring)
      # `publish_tracks/2` sees the pre-batch state, and that is the right
      # answer: a track that expired in this batch was not detected in it, so
      # it is no part of the event this batch's detections opened.
      assert row.event_id == nil
      refute row.event_id == eid
      assert row.end_reason == :unseen
    end
  end

  describe "a track that ended with no event open" do
    setup ctx do
      # no event can open, so every track here takes the tier-gated branch
      CameraControl.put(ctx.camera_id, %{recording_enabled: false})
      :ok
    end

    test "passing the tier gets a row with no event id", ctx do
      oid = start_and_end_track(ctx)

      flush(ctx.tracker, ctx.rec)
      refute_received {:event_started, _}

      row = Tracks.get(oid)
      assert row.event_id == nil
      assert row.best_score == 0.9
      assert row.end_reason == :unseen
      # the track index is written whatever `recording_enabled` says: rows
      # without video are the point of splitting `track:` from `record:`
      assert Tracks.list(camera: ctx.camera_id).total == 1
    end

    test "excluded by the tier gets no row", ctx do
      camera = %{ctx.camera | track: %{"car" => %{min_score: 0.5}}}
      ctx = %{ctx | camera: camera}

      oid = start_and_end_track(ctx, policy: tier(%{"car" => %{min_score: 0.5}}))

      flush(ctx.tracker, ctx.rec)

      assert Tracks.get(oid) == nil
      assert Tracks.list(camera: ctx.camera_id).total == 0
    end

    test "scoring under the tier gets no row", ctx do
      camera = %{ctx.camera | track: %{"person" => %{min_score: 0.95}}}
      ctx = %{ctx | camera: camera}

      oid = start_and_end_track(ctx, score: 0.9, policy: tier(%{"person" => %{min_score: 0.95}}))

      flush(ctx.tracker, ctx.rec)

      assert Tracks.get(oid) == nil
    end

    test "a track retired by turning detection off is recorded like any other", ctx do
      observe(ctx.tracker, ctx.camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])], [])
      assert_receive {:track_started, %Track{object_id: oid}}

      # detection_enabled is gated upstream now (`Cairn.Pipeline.ObservationStamper`),
      # which is what tells the tracker element to let go —
      # `TrackerDriver.end_all/4` is that in-band event, not a further
      # detection under a disabled control this process never sees anyway
      TrackerDriver.end_all(ctx.tracker, ctx.camera, @policy, :detection_disabled)

      assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :detection_disabled}}

      flush(ctx.tracker, ctx.rec)

      assert Tracks.get(oid).end_reason == :detection_disabled
    end

    test "a sparsetrack identity survives the whole way into a row", ctx do
      # The other core a camera may select, through the same seam: its inner
      # ids are per-instance integers, and `Cairn.Tracks.Track`'s primary key is
      # a string — an integer reaches `insert_all` as an `Ecto.ChangeError` that
      # takes the recorder's whole buffer with it, so the adapter's mint is what
      # this asserts, at the only place that can tell.
      observe(ctx.tracker, ctx.camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])],
        core: {Cairn.Detect.SparseTrack, []}
      )

      assert_receive {:track_started, %Track{object_id: oid}}
      assert oid =~ ~r/^[0-9A-HJKMNP-TV-Z]{26}$/

      TrackerDriver.end_all(ctx.tracker, ctx.camera, @policy, :detection_disabled)
      assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :detection_disabled}}

      flush(ctx.tracker, ctx.rec)

      row = Tracks.get(oid)
      assert row.camera_id == ctx.camera_id
      assert row.end_reason == :detection_disabled
      assert row.label == "person"
    end

    test "an evicted track is recorded like any other", ctx do
      policy = Map.put(@policy, :max_live_tracks, 1)

      log =
        capture_log(fn ->
          observe(ctx.tracker, ctx.camera, [object("person", 0.9, [0.0, 0.0, 0.1, 0.1])],
            policy: policy
          )

          assert_receive {:track_started, %Track{object_id: first}}

          observe(ctx.tracker, ctx.camera, [object("person", 0.9, [0.8, 0.8, 0.1, 0.1])],
            at_ms: 2_000.0,
            policy: policy
          )

          assert_receive {:track_ended, %Track{object_id: ^first, end_reason: :evicted}}
          send(self(), {:evicted, first})
        end)

      assert log =~ "live-track cap"
      assert_received {:evicted, first}

      flush(ctx.tracker, ctx.rec)

      assert Tracks.get(first).end_reason == :evicted
    end
  end

  # -- the two tiers together ---------------------------------------------------

  describe "a label the record: tier leaves out" do
    # config.example.yml's worked example, made real: everything over 0.4
    # reaches the host, people at 0.4 and cats at 0.5 earn a track row, and
    # only people, and only at 0.6, ever start a recording. Cats are logged and
    # never filmed — which is the whole reason the two tiers are separate.
    @example_min_score %{"default" => 0.4, "person" => 0.4}
    @example_track %{"person" => %{min_score: 0.4}, "cat" => %{min_score: 0.5}}
    @example_record %{"person" => %{min_score: 0.6}}

    setup ctx do
      camera = %{
        ctx.camera
        | min_score: @example_min_score,
          track: @example_track,
          record: @example_record
      }

      # recording is *enabled* throughout, unlike the tier-gated cases above:
      # what stops the event here is the `record:` block, not the runtime toggle
      %{ctx | camera: camera}
    end

    test "gets a row and no event, however high it scores", ctx do
      oid =
        start_and_end_track(ctx,
          label: "cat",
          score: 0.9,
          policy: tiers(@example_track, @example_record)
        )

      flush(ctx.tracker, ctx.rec)
      refute_received {:event_started, _}

      row = Tracks.get(oid)
      assert row.label == "cat"
      assert row.best_score == 0.9
      # no event was ever open, so the row is the tier-gated kind: unlinked
      assert row.event_id == nil
      assert Tracks.list(camera: ctx.camera_id).total == 1
    end

    test "a person over the record threshold on the same camera does open one", ctx do
      oid =
        start_and_end_track(ctx,
          label: "person",
          score: 0.65,
          policy: tiers(@example_track, @example_record)
        )

      assert_receive {:extractor_started, %Event{id: eid}, _pid}

      flush(ctx.tracker, ctx.rec)

      assert Tracks.get(oid).event_id == eid
    end

    # There used to be a second route here — `detections/4` straight to the
    # tracker versus `Dispatch.forward/4` — proving neither read nor rewrote
    # either tier in transit. That distinction is gone: `observe/4` now always
    # runs the real element and the real `Cairn.Pipeline.TrackSink`, which
    # itself calls `Dispatch.forward/4` to reach this process, so every test
    # above already exercises that one hop end to end. Nothing is left to
    # compare a second route against.
  end

  # -- live rows ----------------------------------------------------------------

  describe "a track that qualifies" do
    setup ctx do
      # recording off throughout: these are about the `track:` tier and the row
      # it opens, and an open event would record every track unconditionally.
      CameraControl.put(ctx.camera_id, %{recording_enabled: false})
      :ok
    end

    test "has a row while it is still running, closed in place when it ends", ctx do
      observe(ctx.tracker, ctx.camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])], [])

      assert_receive {:track_started, %Track{object_id: oid}}
      flush(ctx.tracker, ctx.rec)

      row = Tracks.get(oid)
      assert row
      # live: the row is there and says the object has not left
      assert row.ended_at == nil
      assert row.end_reason == nil
      assert row.best_score == 0.9
      # and its timeline is readable already
      assert [%{kind: :appeared}] = Tracks.moments(oid)
      assert row.entry_bbox == [0.1, 0.1, 0.2, 0.4]

      observe(ctx.tracker, ctx.camera, [], at_ms: 5_000.0)
      assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :unseen}}
      flush(ctx.tracker, ctx.rec)

      closed = Tracks.get(oid)
      assert closed.ended_at != nil
      assert closed.end_reason == :unseen
      # closed in place — the open and the close are the same row
      assert Tracks.list(camera: ctx.camera_id).total == 1
      assert [%{kind: :appeared}] = Tracks.moments(oid)
    end

    test "picks up a better score on the update the throttle releases", ctx do
      observe(ctx.tracker, ctx.camera, [object("person", 0.6, [0.1, 0.1, 0.2, 0.4])], [])

      assert_receive {:track_started, %Track{object_id: oid}}
      flush(ctx.tracker, ctx.rec)
      assert Tracks.get(oid).best_score == 0.6

      # an improving `best_score` is exactly what `maybe_publish_update/2` lets
      # through, so the row moves with the broadcast. The second box overlaps
      # the first, so IoU keeps the identity and the update is an update.
      observe(ctx.tracker, ctx.camera, [object("person", 0.85, [0.14, 0.14, 0.2, 0.4])],
        at_ms: 1_500.0
      )

      assert_receive {:track_updated, %Track{object_id: ^oid, best_score: 0.85}}
      flush(ctx.tracker, ctx.rec)

      row = Tracks.get(oid)
      assert row.best_score == 0.85
      assert row.exit_bbox == [0.14, 0.14, 0.2, 0.4]
      assert row.ended_at == nil
      assert Tracks.list(camera: ctx.camera_id).total == 1
    end
  end

  describe "a track under the track: tier" do
    setup ctx do
      CameraControl.put(ctx.camera_id, %{recording_enabled: false})
      camera = %{ctx.camera | track: %{"person" => %{min_score: 0.8}}}
      %{ctx | camera: camera}
    end

    test "gets its row when its score first crosses, not before", ctx do
      policy = tier(%{"person" => %{min_score: 0.8}})

      observe(ctx.tracker, ctx.camera, [object("person", 0.6, [0.1, 0.1, 0.2, 0.4])],
        policy: policy
      )

      assert_receive {:track_started, %Track{object_id: oid}}
      flush(ctx.tracker, ctx.rec)

      # over the wire floor, under the tier: tracked, broadcast, not indexed
      assert Tracks.get(oid) == nil

      observe(ctx.tracker, ctx.camera, [object("person", 0.85, [0.14, 0.14, 0.2, 0.4])],
        at_ms: 1_500.0,
        policy: policy
      )

      assert_receive {:track_updated, %Track{object_id: ^oid, best_score: 0.85}}
      flush(ctx.tracker, ctx.rec)

      row = Tracks.get(oid)
      assert row
      assert row.ended_at == nil
      assert row.best_score == 0.85
      # the moment buffered before it qualified is written with the row it
      # finally earned, so the timeline starts where the track did
      assert [%{kind: :appeared}] = Tracks.moments(oid)
      assert row.entry_bbox == [0.1, 0.1, 0.2, 0.4]
    end

    test "gets one at exactly the threshold — the tier is a floor, not a bar to beat", ctx do
      policy = tier(%{"person" => %{min_score: 0.8}})

      observe(ctx.tracker, ctx.camera, [object("person", 0.8, [0.1, 0.1, 0.2, 0.4])],
        policy: policy
      )

      assert_receive {:track_started, %Track{object_id: oid, best_score: 0.8}}
      flush(ctx.tracker, ctx.rec)

      assert Tracks.get(oid)
    end

    test "keeps the row it earned when the tier moves out from under it", ctx do
      # A camera reloaded mid-track, with a `track:` block that no longer lists
      # "person". The row exists, so it must be closed rather than abandoned —
      # nothing else would ever close it, and a live row outlives the host that
      # forgot it.
      observe(ctx.tracker, ctx.camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])],
        policy: tier(nil)
      )

      assert_receive {:track_started, %Track{object_id: oid}}
      flush(ctx.tracker, ctx.rec)
      assert Tracks.get(oid).ended_at == nil

      excluding = %{"car" => %{min_score: 0.5}}
      ctx = %{ctx | camera: %{ctx.camera | track: excluding}}

      observe(ctx.tracker, ctx.camera, [], at_ms: 5_000.0, policy: tier(excluding))

      assert_receive {:track_ended, %Track{object_id: ^oid}}
      flush(ctx.tracker, ctx.rec)

      row = Tracks.get(oid)
      assert row.ended_at != nil
      assert row.end_reason == :unseen
    end

    test "that never crosses it has no row, live or ended", ctx do
      policy = tier(%{"person" => %{min_score: 0.8}})

      for at_ms <- [1_000.0, 1_500.0] do
        observe(ctx.tracker, ctx.camera, [object("person", 0.6, [0.1, 0.1, 0.2, 0.4])],
          at_ms: at_ms,
          policy: policy
        )
      end

      assert_receive {:track_started, %Track{object_id: oid}}
      flush(ctx.tracker, ctx.rec)
      assert Tracks.get(oid) == nil

      observe(ctx.tracker, ctx.camera, [], at_ms: 5_000.0, policy: policy)

      assert_receive {:track_ended, %Track{object_id: ^oid}}
      flush(ctx.tracker, ctx.rec)

      assert Tracks.get(oid) == nil
      assert Tracks.moments(oid) == []
      assert Tracks.list(camera: ctx.camera_id).total == 0
    end
  end

  # -- moments ----------------------------------------------------------------

  describe "timeline moments" do
    @stationary_policy Map.put(@policy, :stationary_after_ms, 2_000)
    @parked_box [0.1, 0.1, 0.2, 0.4]

    test "`:appeared` and the stationary flip carry observation times", ctx do
      tracker =
        start_supervised!(
          {CameraTracker,
           camera_id: ctx.camera_id,
           name: nil,
           recorder: ctx.rec,
           start_extractor: fn _camera, _event ->
             {:ok, spawn(fn -> Process.sleep(:infinity) end)}
           end,
           finalize_extractor: fn _pid, _event -> :ok end},
          id: :tracker_moments
        )

      on_exit(fn -> EventCheckpoint.delete(ctx.camera_id) end)

      # A real first epoch, not the driver's `nil` default: the cut below has
      # to be a boundary the element actually crossed, and a transition away
      # from no-epoch-yet is the element's own first buffer, not a cut.
      epoch = Cairn.ULID.generate()
      first = DateTime.add(DateTime.utc_now(), -100, :second)
      second = DateTime.add(first, 1)
      third = DateTime.add(first, 2)

      for {at, at_ms} <- [{first, 1_000.0}, {second, 2_000.0}, {third, 3_000.0}] do
        observe(tracker, ctx.camera, [object("person", 0.9, @parked_box)],
          observed_at: at,
          at_ms: at_ms,
          policy: @stationary_policy,
          epoch: epoch
        )
      end

      assert_receive {:track_started, %Track{object_id: oid}}
      assert_receive {:track_updated, %Track{object_id: ^oid, stationary: true}}

      # a fresh epoch suspends the live track (in the element, on the first
      # buffer that carries it) and the sweep — forced straight past its
      # window — is what ends it; the event is still open, so the row carries
      # its id
      cut_epoch(tracker, ctx.camera, 4_000.0)
      sweep(tracker, ctx.camera, 90_000)
      assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :stream_reset}}

      flush(tracker, ctx.rec)

      assert [appeared, flip] = Tracks.moments(oid)
      assert appeared.kind == :appeared
      assert appeared.bbox == @parked_box
      assert DateTime.compare(appeared.at, first) == :eq
      assert flip.kind == :became_stationary
      # the flip's time is the observation's, not the wall clock of the write
      assert DateTime.compare(flip.at, third) == :eq

      row = Tracks.get(oid)
      assert row.entry_bbox == @parked_box
      assert row.exit_bbox == @parked_box
      assert row.stationary_since != nil
    end

    # The other edge, through the same pipe: a parked object that departs
    # writes `started_moving` into the timeline, timed by the evaluation that
    # closed the exit window on the observation clock — not by the wall clock
    # of the write. The timings are the drift rule's, measured at this scale:
    # parked by 3_000 (settle 2_000 from the first detection), the departure
    # below first fails at 5_000, and the flag goes at 8_000 — the first
    # evaluation `@stationary_exit_ms` (2_500) past the failure that opened
    # the window.
    test "`started_moving` lands in the timeline with its observation time", ctx do
      base = DateTime.add(DateTime.utc_now(), -100, :second)

      park = for n <- 1..3, do: {n * 1_000.0, @parked_box}
      # +0.1 in x per batch: a real departure, five times the drift floor as
      # a rate, each step still overlapping the last far above the base match
      # threshold so identity is never in question
      depart = for k <- 1..5, do: {3_000.0 + k * 1_000, [0.1 + k * 0.1, 0.1, 0.2, 0.4]}

      for {at_ms, bbox} <- park ++ depart do
        observe(ctx.tracker, ctx.camera, [object("person", 0.9, bbox)],
          observed_at: DateTime.add(base, trunc(at_ms), :millisecond),
          at_ms: at_ms,
          policy: @stationary_policy
        )
      end

      assert_receive {:track_started, %Track{object_id: oid}}

      flush(ctx.tracker, ctx.rec)

      assert [appeared, flip, moved] = Tracks.moments(oid)
      assert appeared.kind == :appeared
      assert flip.kind == :became_stationary
      assert DateTime.compare(flip.at, DateTime.add(base, 3_000, :millisecond)) == :eq
      assert moved.kind == :started_moving
      assert DateTime.compare(moved.at, DateTime.add(base, 8_000, :millisecond)) == :eq
    end
  end

  # -- stream resets ----------------------------------------------------------

  describe "stream reset" do
    @reset_box [0.1, 0.1, 0.2, 0.4]

    # The recorder's mailbox read directly. Every entry point of
    # `Cairn.TrackRecorder` is a cast, so a plain pid in its place receives
    # them verbatim — which is the only way to tell one close from two, since
    # both write the same upsert and leave the same row.
    defp tracker_casting_to_self(ctx, id, opts \\ []) do
      start_supervised!(
        {CameraTracker,
         Keyword.merge(
           [
             camera_id: ctx.camera_id,
             name: nil,
             recorder: self(),
             start_extractor: fn _camera, _event ->
               {:ok, spawn(fn -> Process.sleep(:infinity) end)}
             end,
             finalize_extractor: fn _pid, _event -> :ok end
           ],
           opts
         )},
        id: id
      )
      |> tap(fn _tracker -> on_exit(fn -> EventCheckpoint.delete(ctx.camera_id) end) end)
    end

    test "a suspension nothing adopts closes its row exactly once, at the cut", ctx do
      tracker = tracker_casting_to_self(ctx, :tracker_close_once)
      # a real first epoch, so the cut below is a boundary rather than the
      # element's own first buffer
      epoch_a = Cairn.ULID.generate()
      seen_at = DateTime.add(DateTime.utc_now(), -100, :second)

      observe(tracker, ctx.camera, [object("person", 0.9, @reset_box)],
        observed_at: seen_at,
        epoch: epoch_a
      )

      assert_receive {:"$gen_cast", {:open, %Track{object_id: oid}, _event_id}}

      # the cut itself closes nothing: the track may yet come back
      cut_epoch(tracker, ctx.camera, 2_000.0)
      refute_received {:"$gen_cast", {:final, _track, _event}}

      # the sweep, forced straight past its window: nothing has adopted the
      # suspension in the meantime, so it lapses
      sweep(tracker, ctx.camera, 90_000)

      assert_receive {:"$gen_cast", {:final, %Track{object_id: ^oid} = final, _event}}
      assert final.end_reason == :stream_reset
      # the row's `ended_at` is built from this: the last observation, not the
      # minute of waiting that followed it
      assert DateTime.compare(final.last_seen_at, seen_at) == :eq

      # and once: the second sweep has nothing left to end
      sweep(tracker, ctx.camera, 90_000)
      refute_received {:"$gen_cast", {:final, _track, _event}}
    end

    test "an adopted track's row is refreshed onto the new epoch, never closed", ctx do
      tracker = tracker_casting_to_self(ctx, :tracker_adopted_row)
      epoch_a = Cairn.ULID.generate()
      epoch_b = Cairn.ULID.generate()

      observe(tracker, ctx.camera, [object("person", 0.9, @reset_box)], epoch: epoch_a)
      assert_receive {:"$gen_cast", {:open, %Track{object_id: oid, epoch: ^epoch_a}, _event}}

      send(tracker, {:stream_epoch, ctx.camera_id, :main, epoch_b, :source_lost})
      _ = :sys.get_state(tracker)

      observe(tracker, ctx.camera, [object("person", 0.9, @reset_box)], epoch: epoch_b)
      _ = :sys.get_state(tracker)

      # the same row, moved to the stream it is now being seen in
      assert_receive {:"$gen_cast", {:update, %Track{object_id: ^oid, epoch: ^epoch_b}, _event}}
      refute_received {:"$gen_cast", {:final, _track, _event}}
      refute_received {:"$gen_cast", {:discard, _id}}
    end
  end

  # -- restore ----------------------------------------------------------------

  describe "checkpoint restore" do
    test "records every restored track as :host_restart against the checkpointed event", ctx do
      event = %Event{
        id: Ecto.UUID.generate(),
        camera_id: ctx.camera_id,
        started_at: DateTime.utc_now()
      }

      track = %Track{
        object_id: Cairn.ULID.generate(),
        camera_id: ctx.camera_id,
        label: "cat",
        score: 0.6,
        best_score: 0.61,
        bbox: [0.2, 0.2, 0.1, 0.1],
        source: :host,
        started_at: DateTime.utc_now(),
        last_seen_at: DateTime.utc_now()
      }

      EventCheckpoint.put!(ctx.camera_id, event, [track])

      # a second tracker for the same camera: this one runs restore over the
      # checkpoint above
      restored =
        start_supervised!(
          {CameraTracker, camera_id: ctx.camera_id, name: nil, recorder: ctx.rec},
          id: :tracker_restore_recorder
        )

      oid = track.object_id
      assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :host_restart}}

      flush(restored, ctx.rec)

      row = Tracks.get(oid)
      # unconditional: a checkpoint row exists only while an event is open, so
      # every track in it was live during that clip
      assert row.event_id == event.id
      assert row.end_reason == :host_restart
      assert row.label == "cat"
      # nothing was buffered for a track that predates this recorder
      assert row.entry_bbox == nil
      assert Tracks.moments(oid) == []
    end

    # A batch carrying no evidence still moves the tracker — here the open
    # event's only track lapses in it — and the checkpoint is what a
    # replacement process replays. Left at the last evidence-bearing batch's
    # snapshot it replays a final for a track that already ended.
    test "a lifecycle-only batch moves the checkpoint an open event restores from", ctx do
      # The checkpoint is throttled on this clock; the batches below are
      # deliberately more than a throttle window apart on it.
      clock = start_supervised!({Agent, fn -> 0 end}, id: :checkpoint_clock)

      tracker =
        start_supervised!(
          {CameraTracker,
           camera_id: ctx.camera_id,
           name: nil,
           recorder: ctx.rec,
           monotonic_ms: fn -> Agent.get(clock, & &1) end,
           start_extractor: fn _camera, _event ->
             {:ok, spawn(fn -> Process.sleep(:infinity) end)}
           end,
           finalize_extractor: fn _pid, _event -> :ok end},
          id: :tracker_lifecycle_checkpoint
        )

      observe(tracker, ctx.camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])], [])
      assert_receive {:track_started, %Track{object_id: oid}}

      # The broadcast above leaves this process before the batch that carried
      # it is finished with, so the checkpoint is read behind a sync call.
      _ = :sys.get_state(tracker)
      assert {%Event{}, [%Track{object_id: ^oid}]} = EventCheckpoint.get(ctx.camera_id)

      Agent.update(clock, &(&1 + 2_000))

      # No evidence in it at all, and past `max_unseen_ms` (3 000) of the one
      # before: the track lapses and the event stays open on its post window.
      observe(tracker, ctx.camera, [], at_ms: 5_000.0)
      assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :unseen}}

      _ = :sys.get_state(tracker)
      assert {%Event{}, []} = EventCheckpoint.get(ctx.camera_id)

      # …which is what the restore then replays: nothing, rather than a second
      # final for a track this camera already ended.
      restored =
        start_supervised!(
          {CameraTracker, camera_id: ctx.camera_id, name: nil, recorder: ctx.rec},
          id: :tracker_lifecycle_restore
        )

      assert Process.alive?(restored)
      refute_receive {:track_ended, %Track{end_reason: :host_restart}}, 200
    end
  end
end
