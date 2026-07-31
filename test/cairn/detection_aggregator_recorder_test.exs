defmodule Cairn.DetectionAggregatorRecorderTest do
  # The aggregator's half of the track index: which finished tracks earn a row,
  # with which event id, and what lands on their timeline.
  #
  # DataCase, not ExUnit.Case: the rows are read back out of SQLite, and
  # starting an aggregator runs checkpoint restore, which consults the event
  # index.
  use Cairn.DataCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Cairn.Config.Camera
  alias Cairn.{CameraControl, DetectionAggregator, Event, EventCheckpoint, Observation}
  alias Cairn.{Track, TrackRecorder, Tracks}

  @policy %{pre: 5, post: 10, max: 300, max_unseen_ms: 3_000, max_live_tracks: 128}

  setup do
    camera_id = "aggr_#{System.unique_integer([:positive])}"
    camera = %Camera{id: camera_id, rtsp_url: "rtsp://h/1", min_score: %{"default" => 0.5}}
    test_pid = self()

    rec = start_supervised!({TrackRecorder, name: nil, manual: true})

    agg =
      start_supervised!(
        {DetectionAggregator,
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

    %{agg: agg, rec: rec, camera: camera, camera_id: camera_id}
  end

  # -- helpers ----------------------------------------------------------------

  defp observe(agg, camera, objects, opts) do
    policy = Keyword.get(opts, :policy, @policy)

    observation = %Observation{
      pts: 90_000,
      media_ms: Keyword.get(opts, :media_ms, 1_000.0),
      observed_at: Keyword.get(opts, :observed_at, DateTime.utc_now()),
      time_quality: :arrival,
      objects: objects,
      ended_tracks: Keyword.get(opts, :ended_tracks, []),
      tracking: Keyword.get(opts, :tracking, false),
      protocol: :v0
    }

    DetectionAggregator.detections(agg, camera, policy, observation)
  end

  defp object(label, score, bbox, track_id \\ nil) do
    %{
      label: label,
      score: score,
      bbox: bbox,
      track_id: track_id,
      observation_kind: "detected"
    }
  end

  # The plugin is predicting this box rather than detecting it: tracked, never
  # evidence (`Cairn.Observation.detected?/1`), so no event opens for it.
  defp predicted(label, score, bbox, track_id) do
    %{object(label, score, bbox, track_id) | observation_kind: "tracked"}
  end

  # Drains both mailboxes, then drives the recorder's flush by hand: every
  # assertion below is on rows in SQLite rather than on either process's state.
  defp flush(agg, rec) do
    _ = :sys.get_state(agg)
    send(rec, {:flush, :sys.get_state(rec).flush_token})
    _ = :sys.get_state(rec)
    :ok
  end

  # Starts a plugin-owned track "t1", then ends it — the one end path a test
  # can drive without touching timers or epochs.
  defp start_and_end_track(ctx, opts \\ []) do
    policy = Keyword.get(opts, :policy, @policy)
    score = Keyword.get(opts, :score, 0.9)
    label = Keyword.get(opts, :label, "person")

    observe(ctx.agg, ctx.camera, [object(label, score, [0.1, 0.1, 0.2, 0.4], "t1")],
      tracking: true,
      policy: policy
    )

    assert_receive {:track_started, %Track{object_id: oid}}

    observe(ctx.agg, ctx.camera, [],
      tracking: true,
      media_ms: 2_000.0,
      ended_tracks: ["t1"],
      policy: policy
    )

    assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :plugin_ended}}
    oid
  end

  defp tier(rules), do: Map.put(@policy, :track, rules)

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

      flush(ctx.agg, ctx.rec)

      row = Tracks.get(oid)
      assert row.event_id == eid
      assert row.camera_id == ctx.camera_id
      assert row.end_reason == :plugin_ended
      assert row.label == "person"
    end

    test "is recorded with the event id even though it scores under the tier", ctx do
      camera = %{ctx.camera | track: %{"person" => %{min_score: 0.95}}}
      ctx = %{ctx | camera: camera}

      oid = start_and_end_track(ctx, policy: tier(%{"person" => %{min_score: 0.95}}))
      assert_receive {:extractor_started, %Event{id: eid}, _pid}

      flush(ctx.agg, ctx.rec)

      assert Tracks.get(oid).event_id == eid
    end
  end

  describe "a track that expires in the same batch that opens an event" do
    test "is gated on the tier and linked to no event", ctx do
      # A predicted ("tracked") object is never evidence, so this track exists
      # with no event ever having opened for it — and it scores well over the
      # wire floor, so the tier passes it. The assertion is therefore about the
      # linkage and nothing else.
      observe(ctx.agg, ctx.camera, [predicted("person", 0.9, [0.0, 0.0, 0.1, 0.1], "t1")],
        tracking: true,
        media_ms: 1_000.0
      )

      assert_receive {:track_started, %Track{object_id: expiring}}
      refute_received {:event_started, _}

      # One observation, two things at once: media time has jumped past
      # `max_unseen_ms` so the old track expires inside `Tracker.track/3`, and
      # the object it carries is fresh evidence that opens an event.
      observe(ctx.agg, ctx.camera, [object("person", 0.9, [0.8, 0.8, 0.1, 0.1], "t2")],
        tracking: true,
        media_ms: 9_000.0
      )

      assert_receive {:track_ended, %Track{object_id: ^expiring, end_reason: :unseen}}
      assert_receive {:event_started, %Event{id: eid}}

      flush(ctx.agg, ctx.rec)

      row = Tracks.get(expiring)
      # `publish_tracks/3` sees the pre-batch cam state, and that is the right
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
      CameraControl.set(ctx.camera_id, %{recording_enabled: false})
      :ok
    end

    test "passing the tier gets a row with no event id", ctx do
      oid = start_and_end_track(ctx)

      flush(ctx.agg, ctx.rec)
      refute_received {:event_started, _}

      row = Tracks.get(oid)
      assert row.event_id == nil
      assert row.best_score == 0.9
      assert row.end_reason == :plugin_ended
      # the track index is written whatever `recording_enabled` says: rows
      # without video are the point of splitting `track:` from `record:`
      assert Tracks.list(camera: ctx.camera_id).total == 1
    end

    test "excluded by the tier gets no row", ctx do
      camera = %{ctx.camera | track: %{"car" => %{min_score: 0.5}}}
      ctx = %{ctx | camera: camera}

      oid = start_and_end_track(ctx, policy: tier(%{"car" => %{min_score: 0.5}}))

      flush(ctx.agg, ctx.rec)

      assert Tracks.get(oid) == nil
      assert Tracks.list(camera: ctx.camera_id).total == 0
    end

    test "scoring under the tier gets no row", ctx do
      camera = %{ctx.camera | track: %{"person" => %{min_score: 0.95}}}
      ctx = %{ctx | camera: camera}

      oid = start_and_end_track(ctx, score: 0.9, policy: tier(%{"person" => %{min_score: 0.95}}))

      flush(ctx.agg, ctx.rec)

      assert Tracks.get(oid) == nil
    end

    test "a track retired by turning detection off is recorded like any other", ctx do
      observe(ctx.agg, ctx.camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])], [])
      assert_receive {:track_started, %Track{object_id: oid}}

      CameraControl.set(ctx.camera_id, %{detection_enabled: false})

      observe(ctx.agg, ctx.camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])],
        media_ms: 2_000.0
      )

      assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :detection_disabled}}

      flush(ctx.agg, ctx.rec)

      assert Tracks.get(oid).end_reason == :detection_disabled
    end

    test "an evicted track is recorded like any other", ctx do
      policy = Map.put(@policy, :max_live_tracks, 1)

      log =
        capture_log(fn ->
          observe(ctx.agg, ctx.camera, [object("person", 0.9, [0.0, 0.0, 0.1, 0.1])],
            policy: policy
          )

          assert_receive {:track_started, %Track{object_id: first}}

          observe(ctx.agg, ctx.camera, [object("person", 0.9, [0.8, 0.8, 0.1, 0.1])],
            media_ms: 2_000.0,
            policy: policy
          )

          assert_receive {:track_ended, %Track{object_id: ^first, end_reason: :evicted}}
          send(self(), {:evicted, first})
        end)

      assert log =~ "live-track cap"
      assert_received {:evicted, first}

      flush(ctx.agg, ctx.rec)

      assert Tracks.get(first).end_reason == :evicted
    end
  end

  # -- moments ----------------------------------------------------------------

  describe "timeline moments" do
    @stationary_policy Map.put(@policy, :stationary_after_ms, 2_000)
    @parked_box [0.1, 0.1, 0.2, 0.4]

    test "`:appeared` and the stationary flip carry observation times", ctx do
      first = DateTime.utc_now()
      second = DateTime.add(first, 1)
      third = DateTime.add(first, 2)

      for {at, media_ms} <- [{first, 1_000.0}, {second, 2_000.0}, {third, 3_000.0}] do
        observe(ctx.agg, ctx.camera, [object("person", 0.9, @parked_box)],
          observed_at: at,
          media_ms: media_ms,
          policy: @stationary_policy
        )
      end

      assert_receive {:track_started, %Track{object_id: oid}}
      assert_receive {:track_updated, %Track{object_id: ^oid, stationary: true}}

      # a fresh epoch ends the live track; the event is still open, so the row
      # carries its id
      send(ctx.agg, {:stream_epoch, ctx.camera_id, Cairn.ULID.generate(), :source_lost})
      assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :stream_reset}}

      flush(ctx.agg, ctx.rec)

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

      EventCheckpoint.put(ctx.camera_id, event, [track])

      # a second aggregator: this one runs restore over the checkpoint above
      restored =
        start_supervised!(
          {DetectionAggregator, name: nil, recorder: ctx.rec},
          id: :agg_restore_recorder
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
  end
end
