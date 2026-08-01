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

  defp tiers(track, record),
    do: @policy |> Map.put(:track, track) |> Map.put(:record, record)

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

      flush(ctx.agg, ctx.rec)
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

      flush(ctx.agg, ctx.rec)

      assert Tracks.get(oid).event_id == eid
    end
  end

  # -- live rows ----------------------------------------------------------------

  describe "a track that qualifies" do
    setup ctx do
      # recording off throughout: these are about the `track:` tier and the row
      # it opens, and an open event would record every track unconditionally.
      CameraControl.set(ctx.camera_id, %{recording_enabled: false})
      :ok
    end

    test "has a row while it is still running, closed in place when it ends", ctx do
      observe(ctx.agg, ctx.camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4], "t1")],
        tracking: true
      )

      assert_receive {:track_started, %Track{object_id: oid}}
      flush(ctx.agg, ctx.rec)

      row = Tracks.get(oid)
      assert row
      # live: the row is there and says the object has not left
      assert row.ended_at == nil
      assert row.end_reason == nil
      assert row.best_score == 0.9
      # and its timeline is readable already
      assert [%{kind: :appeared}] = Tracks.moments(oid)
      assert row.entry_bbox == [0.1, 0.1, 0.2, 0.4]

      observe(ctx.agg, ctx.camera, [], tracking: true, media_ms: 2_000.0, ended_tracks: ["t1"])
      assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :plugin_ended}}
      flush(ctx.agg, ctx.rec)

      closed = Tracks.get(oid)
      assert closed.ended_at != nil
      assert closed.end_reason == :plugin_ended
      # closed in place — the open and the close are the same row
      assert Tracks.list(camera: ctx.camera_id).total == 1
      assert [%{kind: :appeared}] = Tracks.moments(oid)
    end

    test "picks up a better score on the update the throttle releases", ctx do
      observe(ctx.agg, ctx.camera, [object("person", 0.6, [0.1, 0.1, 0.2, 0.4], "t1")],
        tracking: true
      )

      assert_receive {:track_started, %Track{object_id: oid}}
      flush(ctx.agg, ctx.rec)
      assert Tracks.get(oid).best_score == 0.6

      # an improving `best_score` is exactly what `maybe_publish_update/3` lets
      # through, so the row moves with the broadcast
      observe(ctx.agg, ctx.camera, [object("person", 0.85, [0.3, 0.3, 0.2, 0.4], "t1")],
        tracking: true,
        media_ms: 1_500.0
      )

      assert_receive {:track_updated, %Track{object_id: ^oid, best_score: 0.85}}
      flush(ctx.agg, ctx.rec)

      row = Tracks.get(oid)
      assert row.best_score == 0.85
      assert row.exit_bbox == [0.3, 0.3, 0.2, 0.4]
      assert row.ended_at == nil
      assert Tracks.list(camera: ctx.camera_id).total == 1
    end
  end

  describe "a track under the track: tier" do
    setup ctx do
      CameraControl.set(ctx.camera_id, %{recording_enabled: false})
      camera = %{ctx.camera | track: %{"person" => %{min_score: 0.8}}}
      %{ctx | camera: camera}
    end

    test "gets its row when its score first crosses, not before", ctx do
      policy = tier(%{"person" => %{min_score: 0.8}})

      observe(ctx.agg, ctx.camera, [object("person", 0.6, [0.1, 0.1, 0.2, 0.4], "t1")],
        tracking: true,
        policy: policy
      )

      assert_receive {:track_started, %Track{object_id: oid}}
      flush(ctx.agg, ctx.rec)

      # over the wire floor, under the tier: tracked, broadcast, not indexed
      assert Tracks.get(oid) == nil

      observe(ctx.agg, ctx.camera, [object("person", 0.85, [0.3, 0.3, 0.2, 0.4], "t1")],
        tracking: true,
        media_ms: 1_500.0,
        policy: policy
      )

      assert_receive {:track_updated, %Track{object_id: ^oid, best_score: 0.85}}
      flush(ctx.agg, ctx.rec)

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

      observe(ctx.agg, ctx.camera, [object("person", 0.8, [0.1, 0.1, 0.2, 0.4], "t1")],
        tracking: true,
        policy: policy
      )

      assert_receive {:track_started, %Track{object_id: oid, best_score: 0.8}}
      flush(ctx.agg, ctx.rec)

      assert Tracks.get(oid)
    end

    test "keeps the row it earned when the tier moves out from under it", ctx do
      # A camera reloaded mid-track, with a `track:` block that no longer lists
      # "person". The row exists, so it must be closed rather than abandoned —
      # nothing else would ever close it, and a live row outlives the host that
      # forgot it.
      observe(ctx.agg, ctx.camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4], "t1")],
        tracking: true,
        policy: tier(nil)
      )

      assert_receive {:track_started, %Track{object_id: oid}}
      flush(ctx.agg, ctx.rec)
      assert Tracks.get(oid).ended_at == nil

      excluding = %{"car" => %{min_score: 0.5}}
      ctx = %{ctx | camera: %{ctx.camera | track: excluding}}

      observe(ctx.agg, ctx.camera, [],
        tracking: true,
        media_ms: 2_000.0,
        ended_tracks: ["t1"],
        policy: tier(excluding)
      )

      assert_receive {:track_ended, %Track{object_id: ^oid}}
      flush(ctx.agg, ctx.rec)

      row = Tracks.get(oid)
      assert row.ended_at != nil
      assert row.end_reason == :plugin_ended
    end

    test "that never crosses it has no row, live or ended", ctx do
      policy = tier(%{"person" => %{min_score: 0.8}})

      for media_ms <- [1_000.0, 1_500.0] do
        observe(ctx.agg, ctx.camera, [object("person", 0.6, [0.1, 0.1, 0.2, 0.4], "t1")],
          tracking: true,
          media_ms: media_ms,
          policy: policy
        )
      end

      assert_receive {:track_started, %Track{object_id: oid}}
      flush(ctx.agg, ctx.rec)
      assert Tracks.get(oid) == nil

      observe(ctx.agg, ctx.camera, [],
        tracking: true,
        media_ms: 2_000.0,
        ended_tracks: ["t1"],
        policy: policy
      )

      assert_receive {:track_ended, %Track{object_id: ^oid}}
      flush(ctx.agg, ctx.rec)

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
