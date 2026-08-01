defmodule Cairn.TrackRecorderTest do
  # async: false and DataCase: the recorder writes through the real pool, and
  # `Cairn.Tracks` notes that async sandboxing is not recommended outside
  # PostgreSQL. Every assertion that something *was* written is on the row in
  # SQLite — asserting on the buffers would pass whether or not a flush ever
  # reached the database. Three tests read internal state as well, and only to
  # pin what is being held back or forgotten, which by definition no row shows.
  use Cairn.DataCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Cairn.{Track, TrackRecorder, Tracks}

  setup do
    # unique per test: the application's own `Cairn.TrackRecorder` is running in
    # this environment and may flush another test's tracks into this test's
    # sandbox, so every query here is scoped to a camera only this test uses.
    %{camera_id: "trec_#{System.unique_integer([:positive])}"}
  end

  defp start_recorder(opts \\ []) do
    start_supervised!({TrackRecorder, Keyword.merge([name: nil, manual: true], opts)})
  end

  defp track(camera_id, overrides \\ %{}) do
    started = DateTime.utc_now()

    Map.merge(
      %Track{
        object_id: Cairn.ULID.generate(),
        camera_id: camera_id,
        label: "person",
        score: 0.8,
        best_score: 0.91,
        bbox: [0.5, 0.5, 0.1, 0.2],
        source: :host,
        epoch: "epoch-1",
        started_at: started,
        last_seen_at: DateTime.add(started, 30),
        end_reason: :unseen
      },
      overrides
    )
  end

  # Drives the timer path by hand: `manual: true` suppresses the scheduling,
  # not the token, so the message a test sends is the one the timer would have.
  defp flush(rec) do
    send(rec, {:flush, :sys.get_state(rec).flush_token})
    # the flush is complete once this returns — it queues behind the message
    _ = :sys.get_state(rec)
    :ok
  end

  # Flunks rather than returning nil: a "the row landed" assertion must not be
  # satisfiable by the helper giving up (see
  # `.claude/solutions/vacuous-poll-helper-assertion-exunit-20260726.md`).
  defp await_row(id, attempts \\ 200) do
    case Tracks.get(id) do
      nil when attempts > 0 ->
        Process.sleep(10)
        await_row(id, attempts - 1)

      nil ->
        flunk("track #{id} was never written")

      row ->
        row
    end
  end

  describe "flush triggers" do
    test "the batch flushes on the 200th final, not the 199th", %{camera_id: cam} do
      rec = start_recorder()

      for _ <- 1..199, do: TrackRecorder.record_final(rec, track(cam), nil)
      _ = :sys.get_state(rec)
      assert Tracks.list(camera: cam).total == 0

      TrackRecorder.record_final(rec, track(cam), nil)
      _ = :sys.get_state(rec)
      assert Tracks.list(camera: cam).total == 200
    end

    test "the interval timer flushes what the count cap never reaches", %{camera_id: cam} do
      rec = start_recorder(manual: false, flush_interval_ms: 20)
      final = track(cam)

      TrackRecorder.record_final(rec, final, nil)

      assert await_row(final.object_id).camera_id == cam
    end

    test "a forged or replayed flush token is ignored", %{camera_id: cam} do
      rec = start_recorder()
      first = track(cam)
      second = track(cam)

      TrackRecorder.record_final(rec, first, nil)
      send(rec, {:flush, make_ref()})
      _ = :sys.get_state(rec)
      assert Tracks.get(first.object_id) == nil

      token = :sys.get_state(rec).flush_token
      send(rec, {:flush, token})
      _ = :sys.get_state(rec)
      assert Tracks.get(first.object_id)

      # the token rotated when it was honoured, so the same message a second
      # time is the already-delivered one the discipline exists for
      TrackRecorder.record_final(rec, second, nil)
      send(rec, {:flush, token})
      _ = :sys.get_state(rec)
      assert Tracks.get(second.object_id) == nil

      flush(rec)
      assert Tracks.get(second.object_id)
    end
  end

  describe "live rows" do
    test "a row exists while the track is still running", %{camera_id: cam} do
      rec = start_recorder()
      live = track(cam, %{end_reason: nil})

      TrackRecorder.record_moment(rec, live.object_id, live.started_at, :appeared, [1, 1, 2, 2])
      TrackRecorder.record_open(rec, live, "event-1")
      flush(rec)

      row = Tracks.get(live.object_id)
      assert row
      # what "live" means in this table, and what every reader keys off
      assert row.ended_at == nil
      assert row.end_reason == nil
      assert row.event_id == "event-1"
      assert row.best_score == 0.91
      # the timeline is readable while the track is still running
      assert [%{kind: :appeared}] = Tracks.moments(live.object_id)
      assert row.entry_bbox == [1, 1, 2, 2]
    end

    test "an update refreshes the live row in place", %{camera_id: cam} do
      rec = start_recorder()
      live = track(cam, %{best_score: 0.55, stationary_ms: 0, end_reason: nil})

      TrackRecorder.record_open(rec, live, nil)
      flush(rec)
      assert Tracks.get(live.object_id).best_score == 0.55

      moved =
        track(cam, %{
          object_id: live.object_id,
          best_score: 0.88,
          stationary_ms: 7_000,
          stationary_since: live.started_at,
          bbox: [0.7, 0.7, 0.1, 0.1],
          end_reason: nil
        })

      TrackRecorder.record_update(rec, moved, nil)
      flush(rec)

      row = Tracks.get(live.object_id)
      assert row.best_score == 0.88
      assert row.stationary_ms == 7_000
      assert row.stationary_since != nil
      assert row.exit_bbox == [0.7, 0.7, 0.1, 0.1]
      # still live, and still one row
      assert row.ended_at == nil
      assert Tracks.list(camera: cam).total == 1
    end

    test "a moment recorded after the row is open lands with the next batch", %{camera_id: cam} do
      rec = start_recorder()
      live = track(cam, %{end_reason: nil})

      TrackRecorder.record_moment(rec, live.object_id, live.started_at, :appeared, [1, 1, 2, 2])
      TrackRecorder.record_open(rec, live, nil)
      flush(rec)
      assert [%{kind: :appeared}] = Tracks.moments(live.object_id)

      TrackRecorder.record_moment(
        rec,
        live.object_id,
        DateTime.add(live.started_at, 5),
        :became_stationary,
        [1, 1, 2, 2]
      )

      flush(rec)

      # the flushed `:appeared` is not written a second time — the recorder
      # forgets a track's moments once they are in
      assert [%{kind: :appeared}, %{kind: :became_stationary}] = Tracks.moments(live.object_id)
    end

    test "the final closes the row that is already there", %{camera_id: cam} do
      rec = start_recorder()
      live = track(cam, %{end_reason: nil})

      TrackRecorder.record_open(rec, live, nil)
      flush(rec)
      assert Tracks.get(live.object_id).ended_at == nil

      TrackRecorder.record_final(rec, %{live | end_reason: :unseen}, "event-1")
      flush(rec)

      row = Tracks.get(live.object_id)
      assert row.end_reason == :unseen
      assert DateTime.compare(row.ended_at, live.last_seen_at) == :eq
      assert row.event_id == "event-1"
      # closed in place: the open and the close are one row
      assert Tracks.list(camera: cam).total == 1
    end

    test "an update for a track with no row writes nothing", %{camera_id: cam} do
      rec = start_recorder()
      never = track(cam, %{end_reason: nil})

      # the shape of a track that never passed the caller's tier: moments
      # buffered, no open ever sent
      TrackRecorder.record_moment(rec, never.object_id, never.started_at, :appeared, [0, 0, 1, 1])
      TrackRecorder.record_update(rec, never, nil)
      flush(rec)

      assert Tracks.get(never.object_id) == nil
      assert Tracks.list(camera: cam).total == 0

      # and it is still only an update away from nothing: the open is what
      # creates the row, and it brings the buffered moment with it
      TrackRecorder.record_update(rec, never, nil)
      flush(rec)
      assert Tracks.get(never.object_id) == nil

      TrackRecorder.record_open(rec, never, nil)
      flush(rec)
      assert Tracks.get(never.object_id).entry_bbox == [0, 0, 1, 1]
    end

    test "a re-sent open is an update, not a second row", %{camera_id: cam} do
      rec = start_recorder()
      live = track(cam, %{best_score: 0.6, end_reason: nil})

      TrackRecorder.record_moment(rec, live.object_id, live.started_at, :appeared, [1, 1, 2, 2])
      TrackRecorder.record_open(rec, live, nil)
      flush(rec)

      TrackRecorder.record_open(rec, %{live | best_score: 0.77}, nil)
      flush(rec)

      row = Tracks.get(live.object_id)
      assert row.best_score == 0.77
      # nothing resets: the `:appeared` moment neither doubles nor disappears,
      # and `entry_bbox` survives a write that no longer knows it
      assert [%{kind: :appeared}] = Tracks.moments(live.object_id)
      assert row.entry_bbox == [1, 1, 2, 2]
      assert Tracks.list(camera: cam).total == 1
    end
  end

  describe "pairing" do
    test "a track and its moments land in one batch", %{camera_id: cam} do
      rec = start_recorder()
      final = track(cam, %{bbox: [0.9, 0.9, 0.1, 0.1]})
      at = final.started_at

      TrackRecorder.record_moment(rec, final.object_id, at, :appeared, [0.1, 0.1, 0.2, 0.2])

      TrackRecorder.record_moment(
        rec,
        final.object_id,
        DateTime.add(at, 5),
        :became_stationary,
        [0.5, 0.5, 0.2, 0.2]
      )

      TrackRecorder.record_final(rec, final, "event-1")
      flush(rec)

      row = Tracks.get(final.object_id)
      assert row.event_id == "event-1"
      assert row.label == "person"
      assert row.best_score == 0.91
      assert row.end_reason == :unseen
      assert DateTime.compare(row.ended_at, final.last_seen_at) == :eq
      # entry from the `:appeared` moment, exit from the final summary's box
      assert row.entry_bbox == [0.1, 0.1, 0.2, 0.2]
      assert row.exit_bbox == [0.9, 0.9, 0.1, 0.1]
      # schema-reserved: nothing in the runtime struct says where the best
      # score happened
      assert row.best_bbox == nil

      assert [%{kind: :appeared}, %{kind: :became_stationary}] = Tracks.moments(final.object_id)
    end

    test "moments buffered for a track with no row stay buffered", %{camera_id: cam} do
      rec = start_recorder()
      unqualified = Cairn.ULID.generate()
      final = track(cam)

      TrackRecorder.record_moment(rec, unqualified, DateTime.utc_now(), :appeared, [0, 0, 1, 1])
      TrackRecorder.record_moment(rec, final.object_id, final.started_at, :appeared, [1, 1, 2, 2])
      TrackRecorder.record_final(rec, final, nil)
      flush(rec)

      assert Tracks.get(final.object_id).entry_bbox == [1, 1, 2, 2]
      # unpaired and therefore never offered to `insert_batch/1` (its parent
      # row does not exist, and `track_events.track_id` is a real FK)
      assert Tracks.moments(unqualified) == []
      assert %{^unqualified => %{attrs: nil}} = :sys.get_state(rec).tracks
    end

    test "discard drops a track's buffered moments", %{camera_id: cam} do
      rec = start_recorder()
      final = track(cam)

      TrackRecorder.record_moment(rec, final.object_id, final.started_at, :appeared, [0, 0, 1, 1])
      TrackRecorder.discard(rec, final.object_id)

      # The row is then asked for anyway — the only way the drop is observable
      # in the database, since a discarded track has no row of its own to look
      # at. In production `discard/2` and `record_final/3` are alternatives.
      TrackRecorder.record_final(rec, final, nil)
      flush(rec)

      assert Tracks.get(final.object_id)
      assert Tracks.moments(final.object_id) == []
      assert Tracks.get(final.object_id).entry_bbox == nil
    end
  end

  describe "timestamp precision" do
    # Every other fixture in this file times its tracks with
    # `DateTime.utc_now()`, which is microsecond precision — the one value the
    # `:utc_datetime_usec` columns accept. A real final never is: the plugin
    # writes three decimals, `DateTime.from_iso8601/1` keeps the precision the
    # string carried, and `insert_all` dumps without casting, so a wire-timed
    # final used to raise `ArgumentError` out of `Ecto.Type.check_usec!` and
    # take the recorder down with the whole buffer. Precision is the dimension
    # this corpus held constant (see
    # `.claude/solutions/fixture-corpus-uniform-in-a-dimension-20260729.md`).
    test "a final timed from the wire is written, not fatal", %{camera_id: cam} do
      rec = start_recorder()
      {:ok, started, 0} = DateTime.from_iso8601("2026-08-01T15:33:14.194Z")
      {:ok, last_seen, 0} = DateTime.from_iso8601("2026-08-01T15:33:18.421Z")
      assert started.microsecond == {194_000, 3}

      final =
        track(cam, %{
          started_at: started,
          last_seen_at: last_seen,
          stationary_since: started
        })

      TrackRecorder.record_moment(rec, final.object_id, started, :appeared, [0.1, 0.1, 0.2, 0.2])
      TrackRecorder.record_final(rec, final, nil)
      flush(rec)

      assert Process.alive?(rec)
      row = Tracks.get(final.object_id)
      assert row
      assert DateTime.compare(row.started_at, started) == :eq
      assert DateTime.compare(row.ended_at, last_seen) == :eq
      assert DateTime.compare(row.stationary_since, started) == :eq
      assert [%{kind: :appeared}] = Tracks.moments(final.object_id)
    end

    test "the live paths are timed from the wire too", %{camera_id: cam} do
      # The open and the update are new ways into the same dump, and they carry
      # the same wire time — a live row is written from `started_at` and
      # `stationary_since` long before any final exists to pad them.
      rec = start_recorder()
      {:ok, started, 0} = DateTime.from_iso8601("2026-08-01T15:33:14.194Z")
      {:ok, later, 0} = DateTime.from_iso8601("2026-08-01T15:33:16.007Z")
      assert started.microsecond == {194_000, 3}
      assert later.microsecond == {7_000, 3}

      live =
        track(cam, %{
          started_at: started,
          last_seen_at: started,
          stationary_since: nil,
          end_reason: nil
        })

      TrackRecorder.record_moment(rec, live.object_id, started, :appeared, [0.1, 0.1, 0.2, 0.2])
      TrackRecorder.record_open(rec, live, nil)
      flush(rec)

      assert Process.alive?(rec)
      assert DateTime.compare(Tracks.get(live.object_id).started_at, started) == :eq

      TrackRecorder.record_update(
        rec,
        %{live | stationary_since: later, stationary_ms: 1_800},
        nil
      )

      TrackRecorder.record_moment(rec, live.object_id, later, :became_stationary, [
        0.1,
        0.1,
        0.2,
        0.2
      ])

      flush(rec)

      assert Process.alive?(rec)
      row = Tracks.get(live.object_id)
      assert DateTime.compare(row.stationary_since, later) == :eq
      assert row.ended_at == nil
      assert [%{kind: :appeared}, %{kind: :became_stationary}] = Tracks.moments(live.object_id)
    end
  end

  describe "bounds" do
    test "queued writes are capped, least recently touched dropped", %{camera_id: cam} do
      rec = start_recorder(max_tracks: 4)
      finals = for _ <- 1..6, do: track(cam)

      log =
        capture_log(fn ->
          Enum.each(finals, &TrackRecorder.record_final(rec, &1, nil))
          # inside the block: the casts are asynchronous, so the warning they
          # produce is only guaranteed emitted once the recorder has drained
          _ = :sys.get_state(rec)
        end)

      flush(rec)

      kept = Enum.map(Tracks.list(camera: cam).tracks, & &1.id)
      # 6 casts against a cap of 4: the fifth trips the sweep back to 3, so the
      # oldest two are gone and the sixth arrives after it
      assert length(kept) == 4
      [oldest, second | rest] = finals
      assert Enum.sort(kept) == rest |> Enum.map(& &1.object_id) |> Enum.sort()
      refute oldest.object_id in kept
      refute second.object_id in kept
      assert log =~ "buffering over 4 unfinished tracks"
    end

    test "a swept live track still gets its row closed", %{camera_id: cam} do
      rec = start_recorder(max_tracks: 4)
      live = track(cam, %{end_reason: nil})

      TrackRecorder.record_open(rec, live, nil)
      flush(rec)

      # push the entry out of the recorder's memory entirely
      capture_log(fn ->
        for _ <- 1..6 do
          TrackRecorder.record_moment(rec, Cairn.ULID.generate(), DateTime.utc_now(), :appeared, [
            0,
            0,
            1,
            1
          ])
        end

        _ = :sys.get_state(rec)
      end)

      refute Map.has_key?(:sys.get_state(rec).tracks, live.object_id)

      # an update for a forgotten track is ignored, but the close still lands:
      # nothing may leave a row live because this process lost its memory of it
      TrackRecorder.record_update(rec, %{live | best_score: 0.99}, nil)
      flush(rec)
      assert Tracks.get(live.object_id).best_score == 0.91

      TrackRecorder.record_final(rec, track(cam, %{object_id: live.object_id}), nil)
      flush(rec)

      row = Tracks.get(live.object_id)
      assert row.end_reason == :unseen
      assert row.ended_at != nil
      assert Tracks.list(camera: cam).total == 1
    end

    test "a track's moments are capped, and `:appeared` survives", %{camera_id: cam} do
      rec = start_recorder()
      final = track(cam)
      at = final.started_at

      TrackRecorder.record_moment(rec, final.object_id, at, :appeared, [0.1, 0.1, 0.2, 0.2])

      for i <- 1..40 do
        kind = if rem(i, 2) == 0, do: :became_stationary, else: :started_moving
        TrackRecorder.record_moment(rec, final.object_id, DateTime.add(at, i), kind, [0, 0, 1, 1])
      end

      TrackRecorder.record_final(rec, final, nil)
      flush(rec)

      moments = Tracks.moments(final.object_id)
      assert length(moments) == 32
      # the earliest are kept: `:appeared` is the only source of `entry_bbox`
      assert hd(moments).kind == :appeared
      assert Tracks.get(final.object_id).entry_bbox == [0.1, 0.1, 0.2, 0.2]
    end

    test "moments for tracks that never finish are swept, least recent first", %{camera_id: cam} do
      rec = start_recorder(max_tracks: 8)
      ids = for _ <- 1..12, do: Cairn.ULID.generate()
      now = DateTime.utc_now()

      log =
        capture_log(fn ->
          for {id, i} <- Enum.with_index(ids) do
            TrackRecorder.record_moment(rec, id, DateTime.add(now, i), :appeared, [i, 0, 1, 1])
          end

          _ = :sys.get_state(rec)
        end)

      assert map_size(:sys.get_state(rec).tracks) <= 8
      assert log =~ "over 8 unfinished tracks"

      first = List.first(ids)
      last = List.last(ids)
      TrackRecorder.record_final(rec, track(cam, %{object_id: first}), nil)
      TrackRecorder.record_final(rec, track(cam, %{object_id: last}), nil)
      flush(rec)

      # the swept track still gets its row, only its timeline is gone
      assert Tracks.get(first).entry_bbox == nil
      assert Tracks.moments(first) == []
      # the most recently touched entry survived the sweep
      assert Tracks.get(last).entry_bbox == [11, 0, 1, 1]
    end
  end
end
