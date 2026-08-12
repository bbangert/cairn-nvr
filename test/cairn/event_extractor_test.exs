defmodule Cairn.EventExtractorTest do
  use Cairn.DataCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Cairn.{
    CameraTracker,
    Config,
    Event,
    EventArtifact,
    EventCheckpoint,
    EventExtractor,
    Events,
    MP4.Demuxer,
    Observation,
    Reconciler,
    RingBuffer
  }

  alias Cairn.Config.Camera

  @policy %{pre: 5, post: 10, max: 300, max_unseen_ms: 3_000, max_live_tracks: 128}

  @fixture "test/support/fixtures/media/testsrc.fmp4"

  @artifact_kinds [
    :event_clip_ready,
    :event_clip_failed,
    :event_snapshot_ready,
    :event_snapshot_failed
  ]
  @lifecycle_kinds [:event_started, :event_updated, :event_ended | @artifact_kinds]

  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_ex_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    camera_id = "ex_#{System.unique_integer([:positive])}"
    camera = %Camera{id: camera_id, rtsp_url: "rtsp://h/1"}
    # Remux off by default here so the fragment-level assertions below can
    # read the file back with `Demuxer` — a remuxed clip has no `moof` left to
    # parse. The tests that need the real thing turn it back on per test
    # (`remux_clips: true`), and what the remux does to a clip's *front* — the
    # leading empty edit it writes for samples it could not decode — is
    # `Cairn.ClipRemuxTest`.
    config = %Config{
      data_dir: dir,
      remux_clips: false
    }

    start_supervised!({RingBuffer, camera_id: camera_id, pre_window_seconds: 60})

    Event.subscribe()

    {init_meta, frags} = fixture_events(camera_id)

    RingBuffer.put_init(
      camera_id,
      init_meta.data,
      init_meta.codec,
      init_meta.timescale,
      Cairn.ULID.generate()
    )

    %{camera: camera, config: config, dir: dir, init: init_meta, frags: frags}
  end

  defp fixture_events(camera_id) do
    {_d, events} = Demuxer.push(Demuxer.new(camera_id), File.read!(@fixture))
    [{:init, init} | rest] = events
    {init, Enum.map(rest, fn {:fragment, f} -> f end)}
  end

  defp new_event(camera) do
    %Event{
      id: Ecto.UUID.generate(),
      camera_id: camera.id,
      started_at: DateTime.utc_now(),
      max_scores: %{"person" => 0.9},
      max_score: 0.9,
      labels: [%{t: 0.0, label: "person", score: 0.9, object_id: 1}]
    }
  end

  test "writes pre-window + live fragments into a valid clip and finalizes",
       %{camera: camera, config: config, frags: frags} do
    {pre, live} = Enum.split(frags, 2)
    Enum.each(pre, &RingBuffer.put_fragment(camera.id, &1))

    event = new_event(camera)
    test_pid = self()

    pid =
      start_supervised!(
        {EventExtractor,
         camera: camera,
         event: event,
         config: config,
         snapshot_fun: fn row, _cfg -> send(test_pid, {:snapshot_requested, row.id}) end}
      )

    ref = Process.monitor(pid)

    # active row exists as soon as the extractor is up
    assert %{status: :active, path: path} = wait_row(event.id)

    Enum.each(live, &RingBuffer.put_fragment(camera.id, &1))

    # wait until the extractor has consumed every live fragment before
    # finalizing (ring fanout and the finalize cast race otherwise)
    total = length(frags)
    wait_until(fn -> :sys.get_state(pid).fragments == total end)

    finalized = %{event | ended_at: DateTime.utc_now(), status: :finalized}
    EventExtractor.finalize(pid, finalized)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    # row updated
    row = Events.get(event.id)
    assert row.status == :finalized
    assert row.bytes == File.stat!(path).size
    assert row.labels["max_scores"] == %{"person" => 0.9}
    assert_receive {:snapshot_requested, _}

    # output box-parses as a valid fmp4 with all fragments, no gap/dup at
    # the drain boundary (ring re-stamps seqs monotonically)
    {_d, events} = Demuxer.push(Demuxer.new("check"), File.read!(path))
    assert [{:init, %{codec: codec}} | out_frags] = events
    assert codec =~ ~r/^avc1\./
    out_frags = Enum.map(out_frags, fn {:fragment, f} -> f end)

    assert length(out_frags) == length(frags)
    assert Enum.map(out_frags, & &1.pts) == Enum.map(frags, & &1.pts)
  end

  test "remux_clips rewrites the clip so it reports its real duration",
       %{camera: camera, config: config, frags: frags} do
    {path, _id} = run_to_finalize(camera, %{config | remux_clips: true}, frags)

    # The bug this guards: fragments carry the camera's absolute decode times
    # and declare no duration, so an un-remuxed clip starts partway into a
    # timeline and reports its length as time-since-ffmpeg-started.
    assert {out, 0} =
             System.cmd(
               "ffprobe",
               ~w(-v error -show_entries format=duration,start_time -of csv=p=0) ++ [path]
             )

    [start_time, duration] =
      out |> String.trim() |> String.split(",") |> Enum.map(&elem(Float.parse(&1), 0))

    assert_in_delta start_time, 0.0, 0.001
    assert duration > 0.0
    # remuxed clips carry a real moov with sample tables instead of fragments
    refute File.read!(path) =~ "moof"
  end

  test "remux_clips: false leaves the clip fragmented",
       %{camera: camera, config: config, frags: frags} do
    {path, _id} = run_to_finalize(camera, %{config | remux_clips: false}, frags)

    {_d, events} = Demuxer.push(Demuxer.new("check"), File.read!(path))
    assert [{:init, _} | _] = events
  end

  test "a failed remux keeps the original clip and its byte count",
       %{camera: camera, config: config, frags: frags} do
    {path, id} =
      run_to_finalize(camera, %{config | remux_clips: true}, frags, remux_fun: fn _ -> :error end)

    row = Events.get(id)
    assert row.status == :finalized
    assert row.bytes == File.stat!(path).size

    {_d, events} = Demuxer.push(Demuxer.new("check"), File.read!(path))
    assert [{:init, _} | _] = events
  end

  # Drives one event from first fragment to finalized, returning {path, id}.
  defp run_to_finalize(camera, config, frags, opts \\ []) do
    event = new_event(camera)

    pid =
      start_supervised!(
        {EventExtractor,
         [camera: camera, event: event, config: config, snapshot_fun: fn _row, _cfg -> :ok end] ++
           opts},
        id: {:extractor, event.id}
      )

    ref = Process.monitor(pid)
    assert %{status: :active, path: path} = wait_row(event.id)

    Enum.each(frags, &RingBuffer.put_fragment(camera.id, &1))
    wait_until(fn -> :sys.get_state(pid).fragments == length(frags) end)

    EventExtractor.finalize(pid, %{event | ended_at: DateTime.utc_now(), status: :finalized})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    {path, event.id}
  end

  # What this measures: the clip is never announced before the extractor is
  # told to finalize, it carries its post-remux size, and the snapshot is only
  # kicked off afterwards. The *camera tracker's* ordering is pinned by the
  # two tests below and by the stub test in `CameraTrackerTest`.
  test "the clip is announced only once finalized, carrying its post-remux size",
       %{camera: camera, config: config, frags: frags} do
    config = %{config | remux_clips: true}
    event = new_event(camera)
    test_pid = self()

    pid =
      start_supervised!(
        {EventExtractor,
         camera: camera,
         event: event,
         config: config,
         snapshot_fun: fn row, _cfg -> send(test_pid, {:snapshot_requested, row.id}) end}
      )

    ref = Process.monitor(pid)
    assert %{status: :active, path: path} = wait_row(event.id)

    Enum.each(frags, &RingBuffer.put_fragment(camera.id, &1))
    wait_until(fn -> :sys.get_state(pid).fragments == length(frags) end)
    written = :sys.get_state(pid).bytes

    finalized = %{event | ended_at: DateTime.utc_now(), status: :finalized}
    Event.broadcast(:event_ended, finalized)
    EventExtractor.finalize(pid, finalized)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    event_id = event.id
    camera_id = camera.id

    assert {:event_ended, %Event{id: ^event_id}} = next_lifecycle(camera_id)

    assert {:event_clip_ready,
            %EventArtifact{
              event_id: ^event_id,
              camera_id: ^camera_id,
              path: ^path,
              reason: nil
            } = clip} = next_lifecycle(camera_id)

    # the snapshot is kicked off *after* the clip frame, from the same
    # process — so finding it behind that frame in this mailbox is the proof
    assert_received {:snapshot_requested, ^event_id}

    # the size announced is the remuxed file's, not the bytes the writer
    # streamed: a client sizing a download off it would be lied to otherwise
    assert clip.bytes == File.stat!(path).size
    refute clip.bytes == written
    assert Events.get(event_id).bytes == clip.bytes
  end

  # B2: the guarantee end to end. The camera tracker's own `maybe_finalize/3`
  # supplies the interleaving here — no stub extractor funs, a real extractor
  # doing a real close/remux/index/broadcast on the other side of the cast.
  test "a real camera tracker finalizing a real extractor announces event_ended first",
       %{camera: camera, config: config, frags: frags} do
    test_pid = self()
    on_exit(fn -> EventCheckpoint.delete(camera.id) end)

    tracker =
      start_supervised!({
        CameraTracker,
        # the real extractor; only its data_dir is pinned to this test's, and
        # the snapshot is stubbed so no ffmpeg runs. `finalize_extractor` is
        # left at its default — the real cast.
        camera_id: camera.id,
        name: nil,
        start_extractor: fn cam, event ->
          DynamicSupervisor.start_child(
            Cairn.EventSupervisor,
            {EventExtractor,
             camera: cam,
             event: event,
             config: config,
             snapshot_fun: fn row, _cfg -> send(test_pid, {:snapshot_requested, row.id}) end}
          )
        end
      })

    Enum.each(frags, &RingBuffer.put_fragment(camera.id, &1))
    CameraTracker.detections(tracker, camera, @policy, observation(camera.id))

    assert {:event_started, %Event{id: event_id}} = next_lifecycle(camera.id)
    assert %{status: :active} = wait_row(event_id)

    # fire the post-window timer the tracker armed, with its own token
    send(tracker, {:post_window, event_id, :sys.get_state(tracker).post_token})

    assert {:event_ended, %Event{id: ^event_id, status: :finalized}} = next_lifecycle(camera.id)

    assert {:event_clip_ready, %EventArtifact{event_id: ^event_id, reason: nil}} =
             next_lifecycle(camera.id, 5_000)
  end

  defp observation(camera_id) do
    %Observation{
      camera_id: camera_id,
      pts: 90_000,
      media_ms: 1_000.0,
      observed_at: DateTime.utc_now(),
      time_quality: :arrival,
      objects: [
        %{
          label: "person",
          score: 0.9,
          bbox: [0.1, 0.1, 0.2, 0.4],
          track_id: nil,
          observation_kind: "detected"
        }
      ],
      ended_tracks: [],
      protocol: :v0
    }
  end

  test "a clip the index will not accept is announced failed, not silently dropped",
       %{camera: camera, config: config, frags: frags} do
    event = new_event(camera)
    test_pid = self()

    pid =
      start_supervised!(
        {EventExtractor,
         camera: camera,
         event: event,
         config: config,
         snapshot_fun: fn row, _cfg -> send(test_pid, {:snapshot_requested, row.id}) end}
      )

    ref = Process.monitor(pid)
    assert %{status: :active} = row = wait_row(event.id)
    Enum.each(Enum.take(frags, 2), &RingBuffer.put_fragment(camera.id, &1))

    # retention deleting the event mid-recording: `Events.finalize` then has
    # nothing to update and the clip never becomes reachable
    {:ok, _} = Events.delete_row(row)

    log =
      capture_log(fn ->
        EventExtractor.finalize(pid, %{event | ended_at: DateTime.utc_now(), status: :finalized})
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
      end)

    assert log =~ "finalize failed"

    event_id = event.id
    camera_id = camera.id

    assert_receive {:event_clip_failed,
                    %EventArtifact{
                      event_id: ^event_id,
                      camera_id: ^camera_id,
                      path: nil,
                      bytes: nil,
                      reason: :not_found
                    }}

    refute_received {:event_clip_ready, _}
    # no row, no snapshot to cut from it
    refute_received {:snapshot_requested, _}
  end

  # An update the index rejects is a different failure from a missing row, and
  # the wire reason has to say so: `index_write_failed`, not `not_found`.
  test "an index update the changeset refuses is announced index_write_failed",
       %{camera: camera, config: config, frags: frags} do
    event = new_event(camera)

    # a max_score that is not a number: `Events.finalize`'s changeset refuses
    # the cast, so the row keeps its `active` state and the clip is unreachable
    log = finalize_broken(camera, config, frags, event, %{event | max_score: "very high"}, [])

    assert log =~ "finalize failed"
    event_id = event.id

    assert_receive {:event_clip_failed,
                    %EventArtifact{event_id: ^event_id, reason: :index_write_failed}}

    refute_received {:event_clip_ready, _}
    assert %{status: :active} = Events.get(event.id)
  end

  # B3: `event_ended` is already on the wire by the time finalize runs, so a
  # crash in there must not leave a consumer waiting for a clip frame forever.
  test "a finalize that raises still announces the clip as failed",
       %{camera: camera, config: config, frags: frags} do
    event = new_event(camera)
    finalized = %{event | ended_at: DateTime.utc_now(), status: :finalized}

    log =
      finalize_broken(camera, config, frags, event, finalized,
        remux_clips: true,
        remux_fun: fn _path -> raise "ffmpeg went sideways" end
      )

    assert log =~ "finalize crashed"
    assert_exception_failed(event, camera)
  end

  test "a finalize that exits still announces the clip as failed",
       %{camera: camera, config: config, frags: frags} do
    event = new_event(camera)
    finalized = %{event | ended_at: DateTime.utc_now(), status: :finalized}

    log =
      finalize_broken(camera, config, frags, event, finalized,
        remux_clips: true,
        # what an Ecto pool checkout timeout looks like from in here: an exit,
        # which `rescue` alone would not catch
        remux_fun: fn _path -> exit({:timeout, {DBConnection.Holder, :checkout, []}}) end
      )

    assert log =~ "finalize exited"
    assert_exception_failed(event, camera)
  end

  defp assert_exception_failed(event, camera) do
    event_id = event.id
    camera_id = camera.id

    assert_receive {:event_clip_failed,
                    %EventArtifact{
                      event_id: ^event_id,
                      camera_id: ^camera_id,
                      path: nil,
                      bytes: nil,
                      reason: :exception
                    }}

    refute_received {:event_clip_ready, _}
    # a clip that never landed has no frame to cut a snapshot from
    refute_received {:snapshot_requested, _}
  end

  # Runs an extractor to finalize with a deliberately broken step, returning
  # the captured log. `opts` are extra extractor options (`remux_fun` etc).
  defp finalize_broken(camera, config, frags, event, finalized, opts) do
    test_pid = self()
    {config_opts, opts} = Keyword.split(opts, [:remux_clips])
    config = struct!(config, config_opts)

    pid =
      start_supervised!(
        {EventExtractor,
         [
           camera: camera,
           event: event,
           config: config,
           snapshot_fun: fn row, _cfg -> send(test_pid, {:snapshot_requested, row.id}) end
         ] ++ opts},
        id: {:extractor, event.id}
      )

    ref = Process.monitor(pid)
    assert %{status: :active} = wait_row(event.id)
    Enum.each(Enum.take(frags, 2), &RingBuffer.put_fragment(camera.id, &1))

    capture_log(fn ->
      EventExtractor.finalize(pid, finalized)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end)
  end

  test "crash mid-event leaves an active row that reconciliation marks partial",
       %{camera: camera, config: config, frags: frags} do
    Enum.each(Enum.take(frags, 2), &RingBuffer.put_fragment(camera.id, &1))

    event = new_event(camera)

    pid =
      start_supervised!(
        {EventExtractor, camera: camera, event: event, config: config},
        restart: :temporary
      )

    assert %{status: :active} = wait_row(event.id)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert %{status: :active} = Events.get(event.id)

    summary = Reconciler.run(config)
    assert summary.partialed == 1
    assert %{status: :partial} = Events.get(event.id)

    # a half-written clip is not a ready one: neither the crash nor the
    # cleanup may claim the media landed
    refute_artifacts(camera.id)
  end

  test "reconciliation deletes rows with missing files and adopts orphans",
       %{camera: camera, config: config} do
    # row without file, but with the sidecar its clip left behind. Nothing else
    # would ever collect it: `adopt_orphans/2` globs `*.mp4`, and once the row
    # is gone no route can derive the path again.
    gone = new_event(camera)
    gone_path = Path.join(config.data_dir, "nope.mp4")
    {:ok, _} = Events.create_active(gone, gone_path)
    gone_sidecar = Cairn.DataDir.trackpath_for_clip(gone_path)
    File.write!(gone_sidecar, "tracks")

    # orphan clip on disk with parseable identity
    orphan_id = Ecto.UUID.generate()
    ts = DateTime.to_unix(DateTime.utc_now())
    orphan_path = Cairn.DataDir.event_clip_path(config.data_dir, camera.id, orphan_id, ts)
    File.mkdir_p!(Path.dirname(orphan_path))
    File.write!(orphan_path, "clipdata")

    summary = Reconciler.run(config)
    assert summary.deleted == 1
    assert summary.adopted == 1

    assert Events.get(gone.id) == nil
    refute File.exists?(gone_sidecar)

    orphan = Events.get(orphan_id)
    assert orphan.status == :partial
    assert orphan.camera_id == camera.id
    assert orphan.bytes == 8

    # adopting a clip found on disk is bookkeeping, not an artifact landing
    refute_artifacts(camera.id)
  end

  # `Cairn.Boot` is `:transient`: a failure in one of its later sync steps
  # re-runs reconciliation with cameras — and extractors — already live. Disk
  # is truth only for files nobody is writing; deleting or partialing a row out
  # from under a live extractor makes it announce a false clip failure for a
  # clip that is perfectly fine.
  test "reconciliation leaves a row whose extractor is still recording alone",
       %{camera: camera, config: config, frags: frags} do
    event = new_event(camera)
    test_pid = self()

    pid =
      start_supervised!(
        {EventExtractor,
         camera: camera,
         event: event,
         config: config,
         snapshot_fun: fn row, _cfg -> send(test_pid, {:snapshot_requested, row.id}) end}
      )

    ref = Process.monitor(pid)
    assert %{status: :active} = wait_row(event.id)
    Enum.each(Enum.take(frags, 2), &RingBuffer.put_fragment(camera.id, &1))
    wait_until(fn -> :sys.get_state(pid).fragments == 2 end)

    assert %{deleted: 0, partialed: 0, adopted: 0} = Reconciler.run(config)
    assert %{status: :active} = Events.get(event.id)

    # and the event still finalizes into a ready clip, not a false failure
    EventExtractor.finalize(pid, %{event | ended_at: DateTime.utc_now(), status: :finalized})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    event_id = event.id
    assert_receive {:event_clip_ready, %EventArtifact{event_id: ^event_id}}
    refute_received {:event_clip_failed, _}
  end

  describe "the track path sidecar" do
    # The pre-roll `run_with_boxes/5` drains unless a test passes
    # `pre_roll: false`: the fixture's second and third fragments, pts 10_240
    # and 20_480 at timescale 10_240, 1_000 ms each. Not the first two, so a
    # first_pts of 0 cannot pass for a captured anchor.
    @first_pts 10_240
    @timescale 10_240
    # (20_480 − 10_240) / 10_240 × 1000 = 1_000 ms between the two decode
    # times, plus the last fragment's own 1_000 ms to reach the end of the
    # drained media.
    @drained_span_ms 2_000

    defp pre_roll(frags), do: Enum.slice(frags, 1, 2)

    # Drives one event to finalized with `batches` cast in as a camera tracker
    # would, returning `%{path:, event:, opened_ms:, live_ms:}`.
    #
    # `opts` may carry `pre_roll: false` (start with an empty ring),
    # `live:` (fragments put into the ring *after* the extractor subscribed,
    # so they reach it as live ones), `max_path_entries:` (passed to the
    # extractor), and `on_clip_ready:`, a one-arity fun handed the clip path at
    # the moment the artifact frame arrives and *before* `:DOWN` — the only
    # window in which the sidecar write's ordering against the broadcast is
    # observable at all.
    defp run_with_boxes(camera, config, frags, batches, opts \\ []) do
      drained = if Keyword.get(opts, :pre_roll, true), do: pre_roll(frags), else: []
      Enum.each(drained, &RingBuffer.put_fragment(camera.id, &1))

      event = new_event(camera)

      pid =
        start_supervised!(
          {EventExtractor,
           [camera: camera, event: event, config: config, snapshot_fun: fn _row, _cfg -> :ok end] ++
             Keyword.take(opts, [:max_path_entries])},
          id: {:extractor, event.id}
        )

      ref = Process.monitor(pid)
      assert %{status: :active, path: path} = wait_row(event.id)

      # The row is inserted at the top of `handle_continue(:open, ...)`, so
      # `wait_row/1` alone proves nothing about the drain. This sync does: a
      # system message is only answered once the continue has returned, so the
      # anchor's wall clock was read strictly before the mark below.
      drained_count = :sys.get_state(pid).fragments
      opened_ms = DateTime.to_unix(DateTime.utc_now(), :millisecond)

      # Not a poll and not a settle for a race: this sleep *is* the instrument
      # the `drain_wall_ms` bracket is made of. The anchor's clock is supposed
      # to be read at the drain, and the only thing that distinguishes that
      # from a clock read in the finalize handler is real elapsed time between
      # the mark above and the finalize below. Opt-in, so one test pays for it.
      if settle = opts[:settle_ms], do: Process.sleep(settle)

      # The same instrument, for the live half of the anchor: the mark is taken
      # after the drain has provably returned, so a `live_wall_ms` at or after
      # it cannot be the clock the drain read. The wait counts up from what the
      # drain wrote — a camera whose ring still holds an earlier test's
      # fragments drains more than `pre_roll/1` put there.
      live = Keyword.get(opts, :live, [])
      live_ms = DateTime.to_unix(DateTime.utc_now(), :millisecond)
      Enum.each(live, &RingBuffer.put_fragment(camera.id, &1))
      wait_until(fn -> :sys.get_state(pid).fragments == drained_count + length(live) end)

      Enum.each(batches, &GenServer.cast(pid, {:track_boxes, &1}))

      # Same sender, same receiver as the batches: the finalize cast cannot
      # overtake them. That is the whole reason the flush needs no draining
      # handshake — see `Cairn.CameraTracker.forward_boxes/3`.
      EventExtractor.finalize(pid, %{event | ended_at: DateTime.utc_now(), status: :finalized})

      if fun = Keyword.get(opts, :on_clip_ready) do
        event_id = event.id
        assert_receive {:event_clip_ready, %EventArtifact{event_id: ^event_id}}, 10_000
        fun.(path)
      end

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000

      %{path: path, event: event, opened_ms: opened_ms, live_ms: live_ms}
    end

    defp sidecar!(clip_path) do
      path = Cairn.DataDir.trackpath_for_clip(clip_path)
      assert File.exists?(path), "no sidecar at #{path}"
      assert {:ok, map} = Cairn.TrackPath.decode(File.read!(path))
      map
    end

    test "buffered batches become a sidecar beside the clip, anchored to the drain",
         %{camera: camera, config: config, frags: frags} do
      before_ms = DateTime.to_unix(DateTime.utc_now(), :millisecond)

      %{path: path, event: event, opened_ms: opened_ms} =
        run_with_boxes(
          camera,
          config,
          frags,
          [
            %{t_ms: 0, boxes: [{"obj-a", "person", [0.1, 0.2, 0.3, 0.4], false}]},
            %{t_ms: 500, boxes: [{"obj-a", "person", [0.5, 0.25, 0.3, 0.4], true}]}
          ],
          settle_ms: 25
        )

      map = sidecar!(path)

      assert map["v"] == 1
      assert map["event_id"] == event.id
      assert map["camera_id"] == camera.id
      assert map["truncated"] == false

      # Stored exactly as `Cairn.TrackPath` documents it: quantized by 10_000
      # and delta-encoded, both columns and axis. Literals, not a call back
      # into the encoder — the browser overlay has to match these bytes.
      assert map["ts"] == [0, 500]

      assert [
               %{
                 "id" => "obj-a",
                 "label" => "person",
                 "truncated" => false,
                 "ti" => [0, 1],
                 "x" => [1_000, 4_000],
                 "y" => [2_000, 500],
                 "w" => [3_000, 0],
                 "h" => [4_000, 0]
               }
             ] = map["tracks"]

      assert %{
               "first_pts" => @first_pts,
               "timescale" => @timescale,
               "drained_span_ms" => @drained_span_ms,
               # No fragment arrived after the subscribe, so the live half was
               # never taken — the shape a reader must fall back from, and the
               # shape every sidecar written before it existed has.
               "live_media_ms" => nil,
               "live_wall_ms" => nil
             } = map["anchor"]

      assert map["anchor"]["event_started_ms"] ==
               DateTime.to_unix(event.started_at, :millisecond)

      # Bracketed by "before the extractor existed" and "the open had returned",
      # so a clock read anywhere later — in the finalize handler, say — falls
      # outside. `Cairn.EventExtractor`'s anchor is only worth having because
      # it is read *at* the drain.
      assert map["anchor"]["drain_wall_ms"] >= before_ms
      assert map["anchor"]["drain_wall_ms"] <= opened_ms
    end

    test "the first live fragment adds the sharper half of the anchor",
         %{camera: camera, config: config, frags: frags} do
      # Pre-roll is frags 1 and 2 (pts 10_240 and 20_480); frag 3 arrives live
      # at pts 30_720. Its end on the clip's timeline, by hand:
      #   (30_720 − 10_240) / 10_240 × 1000 = 2_000 ms from the clip's t=0 to
      #   this fragment's start, plus its own 1_000 ms to its end.
      %{path: path, live_ms: live_ms} =
        run_with_boxes(
          camera,
          config,
          frags,
          [%{t_ms: 0, boxes: [{"obj-a", "person", [0.1, 0.2, 0.3, 0.4], false}]}],
          live: [Enum.at(frags, 3)],
          settle_ms: 25
        )

      anchor = sidecar!(path)["anchor"]

      assert anchor["live_media_ms"] == 3_000

      # The 25 ms settle sits between the drain and the mark, so a live clock
      # read at the drain — the bug this half exists to fix — lands below it.
      assert anchor["live_wall_ms"] >= live_ms
      assert anchor["live_wall_ms"] > anchor["drain_wall_ms"]

      # and the drain half is still written beside it, not replaced by it
      assert anchor["drained_span_ms"] == @drained_span_ms
      assert anchor["first_pts"] == @first_pts
    end

    test "only the first live fragment sets it, not every one after",
         %{camera: camera, config: config, frags: frags} do
      # frags 3 and 4, in that order. Were the anchor re-taken per fragment,
      # frag 4 (pts 40_960) would leave 4_000 here instead of 3_000, and a
      # later clock with it.
      %{path: path} =
        run_with_boxes(
          camera,
          config,
          frags,
          [%{t_ms: 0, boxes: [{"obj-a", "person", [0.1, 0.2, 0.3, 0.4], false}]}],
          live: [Enum.at(frags, 3), Enum.at(frags, 4)]
        )

      assert sidecar!(path)["anchor"]["live_media_ms"] == 3_000
    end

    test "with no pre-roll drained, the first live fragment is the clip's t=0",
         %{camera: camera, config: config, frags: frags} do
      # Nothing in the ring, so frag 3 is the first thing written after the
      # init segment: the clip is rebased to *its* pts, and its own 1_000 ms is
      # the whole of the media before its end. Reading its pts as an offset
      # instead would put 4_000 here.
      %{path: path} =
        run_with_boxes(
          camera,
          config,
          frags,
          [%{t_ms: 0, boxes: [{"obj-a", "person", [0.1, 0.2, 0.3, 0.4], false}]}],
          pre_roll: false,
          live: [Enum.at(frags, 3)]
        )

      anchor = sidecar!(path)["anchor"]

      assert anchor["live_media_ms"] == 1_000
      assert anchor["drained_span_ms"] == nil

      # The whole point of the case: with only a drain half this file placed
      # nothing at all — `drained_span_ms` is the field the arithmetic needs —
      # and the live half is what makes it placeable.
      drain_only = Map.drop(anchor, ["live_media_ms", "live_wall_ms"])
      assert Cairn.TrackPath.anchor_clip_ms(drain_only, 5_000) == :error
      assert {:ok, clip_ms} = Cairn.TrackPath.anchor_clip_ms(anchor, 5_000)
      # 5_000 shifted by the sub-second gap between the event's start and the
      # fragment's arrival — a bound and not a literal, because that gap is
      # real elapsed time.
      assert clip_ms > 4_000
    end

    test "the sidecar is on disk before event_clip_ready goes out",
         %{camera: camera, config: config, frags: frags} do
      # `Cairn.EventExtractor` puts the write ahead of the broadcast so a
      # consumer that answers `:event_clip_ready` by fetching the sidecar
      # cannot race it. The assertion runs on the frame, not after `:DOWN`, so
      # everything the extractor does afterwards is outside the window.
      #
      # 10_000 boxes, deliberately: encoding, gzipping and writing them takes
      # long enough that a write moved below the broadcast loses the race to
      # this process, which the broadcast has already made runnable. A
      # two-sample sidecar is written too fast for the swap to be visible.
      batches =
        for t <- 0..199 do
          %{
            t_ms: t * 10,
            boxes: for(i <- 1..50, do: {"obj-#{i}", "person", [i / 100, 0.1, 0.1, 0.1], false})
          }
        end

      run_with_boxes(camera, config, frags, batches,
        on_clip_ready: fn clip ->
          assert File.exists?(Cairn.DataDir.trackpath_for_clip(clip)),
                 "the sidecar was not on disk when :event_clip_ready went out"
        end
      )
    end

    test "an empty pre-roll and no live fragment leaves no sidecar to place",
         %{camera: camera, config: config, frags: frags} do
      # Nothing put into the ring and nothing arriving after: a camera whose
      # pre-window has not filled yet, on an event too short to see a fragment.
      # No fragment was written, so there is no clip and no anchor half at all —
      # this used to leave a sidecar whose two media positions were both nil, a
      # file that existed only to say nothing beside a clip announced ready. The
      # reader's side of that shape (an anchor that can place nothing answers
      # `:error` rather than guessing) is covered in `Cairn.TrackPathTest`.
      %{path: path, event: event} =
        capture_and_run(fn ->
          run_with_boxes(
            camera,
            config,
            frags,
            [%{t_ms: 0, boxes: [{"obj-a", "person", [0.1, 0.2, 0.3, 0.4], false}]}],
            pre_roll: false
          )
        end)

      refute File.exists?(Cairn.DataDir.trackpath_for_clip(path))

      event_id = event.id

      assert_receive {:event_clip_failed,
                      %EventArtifact{event_id: ^event_id, reason: :no_keyframe}}

      assert %{status: :partial} = Events.get(event_id)
    end

    # `capture_log/1` answers the log, not the block's value; the no-media path
    # logs a warning that would otherwise print through the suite.
    defp capture_and_run(fun) do
      test_pid = self()
      capture_log(fn -> send(test_pid, {:ran, fun.()}) end)
      assert_received {:ran, result}
      result
    end

    test "an event that saw no boxes writes no file at all",
         %{camera: camera, config: config, frags: frags} do
      %{path: path} = run_with_boxes(camera, config, frags, [])

      # the clip is fine — it is the sidecar that is deliberately absent, which
      # is how a reader is told this event has no path to draw
      assert File.exists?(path)
      refute File.exists?(Cairn.DataDir.trackpath_for_clip(path))
    end

    test "an empty batch leaves no file and costs nothing against the cap",
         %{camera: camera, config: config, frags: frags} do
      # A batch whose tagged list came back empty is not "a path with no
      # samples", it is no path — and a cap of one box proves the two empty
      # batches around it consumed none of the budget.
      %{path: path} =
        run_with_boxes(
          camera,
          config,
          frags,
          [
            %{t_ms: 0, boxes: []},
            %{t_ms: 100, boxes: [{"obj-a", "person", [0.1, 0.2, 0.3, 0.4], false}]},
            %{t_ms: 200, boxes: []}
          ],
          max_path_entries: 1
        )

      map = sidecar!(path)
      assert map["truncated"] == false
      assert Enum.map(map["tracks"], & &1["id"]) == ["obj-a"]
      # only the batch that carried a box is on the axis
      assert map["ts"] == [100]

      %{path: empty} =
        run_with_boxes(camera, config, frags, [%{t_ms: 0, boxes: []}], max_path_entries: 1)

      refute File.exists?(Cairn.DataDir.trackpath_for_clip(empty))
    end

    test "the global entry cap drops the tail and says so in the header",
         %{camera: camera, config: config, frags: frags} do
      # 20 boxes exactly — the cap itself, which is allowed — spread over four
      # object ids, then the one box that does not fit. Run at an overridden
      # cap rather than the 200k default: the boundary is the whole assertion
      # and it is the same boundary at either number.
      ids = ["obj-a", "obj-b", "obj-c", "obj-d"]

      full =
        for batch <- 0..3 do
          boxes =
            for i <- 1..5 do
              {Enum.at(ids, rem(i - 1, 4)), "person", [0.1, 0.1, 0.2, 0.4], false}
            end

          %{t_ms: batch * 100, boxes: boxes}
        end

      over = %{t_ms: 9_999, boxes: [{"obj-late", "car", [0.5, 0.5, 0.1, 0.1], false}]}

      log =
        capture_log(fn ->
          %{path: path} =
            run_with_boxes(camera, config, frags, full ++ [over], max_path_entries: 20)

          map = sidecar!(path)

          assert map["truncated"] == true
          # the dropped batch is the only source of this id, so its absence is
          # the drop, and the four that fit are all still there
          assert Enum.map(map["tracks"], & &1["id"]) == ids
          # The axis is delta-encoded, so its running sum ends at the last
          # *kept* batch — 3 × 100 ms — and never at the 9_999 of the batch the
          # cap dropped. The cap takes the tail, not the head.
          assert Enum.sum(map["ts"]) == 300
        end)

      assert log =~ "track path capped at 20 boxes"
    end

    test "past the cap every later batch is dropped, however small",
         %{camera: camera, config: config, frags: frags} do
      # 15 boxes in, a cap of 20, and then a batch of 10 that cannot fit. The
      # 5 boxes of headroom it leaves behind are the point: the single-box
      # batch after it *would* fit, and is dropped anyway, because a path with
      # interleaved holes is drawn as straight lines across them while a path
      # that stops is announced by `truncated`.
      ids = ["obj-a", "obj-b", "obj-c"]

      full =
        for batch <- 0..4 do
          boxes = for id <- ids, do: {id, "person", [0.1, 0.1, 0.2, 0.4], false}
          %{t_ms: batch * 100, boxes: boxes}
        end

      over = %{
        t_ms: 500,
        boxes: for(i <- 1..10, do: {"obj-over-#{i}", "car", [0.5, 0.5, 0.1, 0.1], false})
      }

      fits = %{t_ms: 600, boxes: [{"obj-after", "person", [0.2, 0.2, 0.1, 0.1], false}]}

      log =
        capture_log(fn ->
          %{path: path} =
            run_with_boxes(camera, config, frags, full ++ [over, fits], max_path_entries: 20)

          map = sidecar!(path)

          assert map["truncated"] == true
          assert Enum.map(map["tracks"], & &1["id"]) == ids
          # the axis stops at the last kept batch, 4 × 100 ms
          assert Enum.sum(map["ts"]) == 400
        end)

      # one line, not one per dropped batch
      assert log |> String.split("track path capped") |> length() == 2
    end

    test "a clip the index refuses leaves no sidecar behind",
         %{camera: camera, config: config, frags: frags} do
      Enum.each(pre_roll(frags), &RingBuffer.put_fragment(camera.id, &1))
      event = new_event(camera)

      pid =
        start_supervised!(
          {EventExtractor, camera: camera, event: event, config: config},
          id: {:extractor, event.id}
        )

      ref = Process.monitor(pid)
      assert %{status: :active, path: path} = row = wait_row(event.id)

      GenServer.cast(
        pid,
        {:track_boxes, %{t_ms: 0, boxes: [{"obj-a", "person", [0.1, 0.2, 0.3, 0.4], false}]}}
      )

      # retention deleting the event mid-recording: `Events.finalize` has
      # nothing to update, so the clip never becomes reachable — and an
      # unreachable clip must not leave a sidecar for a reader to find
      {:ok, _} = Events.delete_row(row)

      capture_log(fn ->
        EventExtractor.finalize(pid, %{event | ended_at: DateTime.utc_now(), status: :finalized})
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
      end)

      event_id = event.id
      assert_receive {:event_clip_failed, %EventArtifact{event_id: ^event_id}}
      refute File.exists?(Cairn.DataDir.trackpath_for_clip(path))
    end

    test "a sidecar that cannot be written costs the clip nothing",
         %{camera: camera, config: config, frags: frags} do
      Enum.each(pre_roll(frags), &RingBuffer.put_fragment(camera.id, &1))
      event = new_event(camera)

      pid =
        start_supervised!(
          {EventExtractor,
           camera: camera, event: event, config: config, snapshot_fun: fn _row, _cfg -> :ok end},
          id: {:extractor, event.id}
        )

      ref = Process.monitor(pid)
      assert %{status: :active, path: path} = wait_row(event.id)

      # a directory standing where the file goes, so `File.write/2` can only
      # answer `{:error, :eisdir}`
      File.mkdir_p!(Cairn.DataDir.trackpath_for_clip(path))

      GenServer.cast(
        pid,
        {:track_boxes, %{t_ms: 0, boxes: [{"obj-a", "person", [0.1, 0.2, 0.3, 0.4], false}]}}
      )

      log =
        capture_log(fn ->
          EventExtractor.finalize(pid, %{event | ended_at: DateTime.utc_now(), status: :finalized})

          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
        end)

      assert log =~ "track path write failed"

      # the clip is announced exactly as it would have been: losing the path
      # loses the overlay, not the video
      event_id = event.id
      assert_receive {:event_clip_ready, %EventArtifact{event_id: ^event_id}}
      refute_received {:event_clip_failed, _}
      assert %{status: :finalized} = Events.get(event_id)
    end

    test "deleting the event deletes the sidecar with the clip",
         %{camera: camera, config: config, frags: frags} do
      %{path: path, event: event} =
        run_with_boxes(camera, config, frags, [
          %{t_ms: 0, boxes: [{"obj-a", "person", [0.1, 0.2, 0.3, 0.4], false}]}
        ])

      sidecar = Cairn.DataDir.trackpath_for_clip(path)
      assert File.exists?(sidecar)

      assert {:ok, _} = Events.delete(Events.get(event.id))

      refute File.exists?(sidecar)
      refute File.exists?(path)
      assert Events.get(event.id) == nil
    end
  end

  # The whole of this block runs on `@mid_gop_fixture`, whose fragments are
  # NOT all keyframe-headed — the dimension `testsrc.fmp4` holds constant, and
  # the one every assertion here turns on.
  describe "the clip starts on a keyframe" do
    # 8 one-second fragments at timescale 10_240; fragments 0, 3 and 6 open a
    # GOP and the rest sit inside one. Written out because the fragment
    # indexes below are meaningless without it.
    @gop_timescale 10_240

    test "a pre-roll that starts mid-GOP is cut back to the first keyframe",
         %{camera: camera, config: config} do
      frags = mid_gop_frags(camera.id)

      # Fragments 1 and 2 are inside fragment 0's GOP; 3 opens the next one.
      # Handed to the remux as-is, 1 and 2 are samples `-c copy` cannot carry
      # and it drops them, recording a 2_000 ms empty edit in their place.
      %{path: path, pid: pid, event: event} =
        run_keyframe_case(camera, %{config | remux_clips: true},
          drained: take(frags, [1, 2, 3, 4])
        )

      written = :sys.get_state(pid).fragments

      finalize!(pid, event)

      out = File.read!(path)
      refute Cairn.MP4Boxes.leading_empty_edit?(out)
      refute Enum.any?(Cairn.MP4Boxes.edit_list(out), &match?({_, -1}, &1))

      [start_time, duration] = probe(path, "format=start_time,duration")
      assert_in_delta start_time, 0.0, 0.001

      anchor = sidecar!(path)["anchor"]

      # Measured from the KEPT head: fragment 3's pts, and the 2_000 ms that
      # fragments 3 and 4 span. Reading them off the drained list instead
      # would leave 10_240 and 4_000 here — the dropped fragments counted as
      # media the file does not hold.
      assert anchor["first_pts"] == 3 * @gop_timescale
      assert anchor["timescale"] == @gop_timescale
      assert anchor["drained_span_ms"] == 2_000

      # And the property all of it exists for: where the anchor puts the
      # event's t=0 is where the file's playable media ends. `start_time` is
      # 0.0 above, so `duration` is entirely media — no empty edit inflating
      # it — and the anchor agrees with it to within the sub-second gap
      # between the event's start and the drain's clock.
      assert {:ok, clip_ms} = Cairn.TrackPath.anchor_clip_ms(anchor, 0)
      assert_in_delta clip_ms / 1000, duration - start_time, 0.25

      assert written == 2
    end

    test "only the leading run is dropped, not every fragment inside a GOP",
         %{camera: camera, config: config} do
      # Fragment 3 opens a GOP and 4 and 5 are inside it — the clip needs all
      # three. A rule that dropped every non-keyframe fragment rather than the
      # leading run would keep one fragment here and throw away two seconds of
      # perfectly decodable video.
      frags = mid_gop_frags(camera.id)

      %{path: path, pid: pid, event: event} =
        run_keyframe_case(camera, config, drained: take(frags, [3, 4, 5]))

      assert :sys.get_state(pid).fragments == 3

      finalize!(pid, event)

      anchor = sidecar!(path)["anchor"]
      assert anchor["first_pts"] == 3 * @gop_timescale
      assert anchor["drained_span_ms"] == 3_000

      {_d, events} = Demuxer.push(Demuxer.new("check"), File.read!(path))
      out_frags = for {:fragment, f} <- events, do: f.pts
      assert out_frags == Enum.map(3..5, &(&1 * @gop_timescale))
    end

    test "a pre-roll with no keyframe in it leaves nothing, and a live keyframe opens the clip",
         %{camera: camera, config: config} do
      # Both drained fragments are mid-GOP, so the drain contributes nothing
      # and the file holds only its init segment until fragment 3 arrives.
      frags = mid_gop_frags(camera.id)

      %{path: path, pid: pid, event: event} =
        run_keyframe_case(camera, config,
          drained: take(frags, [1, 2]),
          live: take(frags, [3, 4])
        )

      assert :sys.get_state(pid).fragments == 2

      finalize!(pid, event)

      anchor = sidecar!(path)["anchor"]

      # An empty kept pre-roll is the same shape as an empty ring: no media
      # position in the drain half at all.
      assert anchor["first_pts"] == nil
      assert anchor["drained_span_ms"] == nil
      # Fragment 3 is the first thing the file holds, so it starts at the
      # clip's t=0 and its own 1_000 ms is where it ends.
      assert anchor["live_media_ms"] == 1_000

      {_d, events} = Demuxer.push(Demuxer.new("check"), File.read!(path))
      assert [{:init, _} | out] = events

      assert Enum.map(out, fn {:fragment, f} -> f.pts end) == [
               3 * @gop_timescale,
               4 * @gop_timescale
             ]
    end

    test "live fragments before the first keyframe are skipped like drained ones",
         %{camera: camera, config: config} do
      # Nothing drained, and the ring then streams the middle of a GOP — a
      # camera whose ring was just cleared by an ffmpeg respawn. Without the
      # live path applying the same rule, the empty edit comes straight back
      # through here.
      frags = mid_gop_frags(camera.id)

      %{path: path, pid: pid, event: event} =
        run_keyframe_case(camera, %{config | remux_clips: true},
          drained: [],
          live: take(frags, [1, 2, 3, 4])
        )

      assert %{fragments: 2, skipped_fragments: 2, skipped_ms: 2_000} = :sys.get_state(pid)

      finalize!(pid, event)

      refute Cairn.MP4Boxes.leading_empty_edit?(File.read!(path))
      [start_time, _duration] = probe(path, "format=start_time,duration")
      assert_in_delta start_time, 0.0, 0.001

      anchor = sidecar!(path)["anchor"]
      assert anchor["first_pts"] == nil
      assert anchor["live_media_ms"] == 1_000
    end

    test "a keyframe-aligned camera loses no pre-roll at all",
         %{camera: camera, config: config, frags: frags} do
      # `testsrc.fmp4`, where every fragment opens a GOP — a reolink-class
      # camera. Nothing may be dropped here, and the anchor must be exactly
      # what it was before any of this existed.
      %{path: path, pid: pid, event: event} =
        run_keyframe_case(camera, config, drained: pre_roll(frags))

      assert :sys.get_state(pid).fragments == 2
      assert :sys.get_state(pid).skipped_fragments == 0

      finalize!(pid, event)

      anchor = sidecar!(path)["anchor"]
      assert anchor["first_pts"] == 10_240
      assert anchor["drained_span_ms"] == 2_000
    end

    test "a shortened drained pre-roll is reported once, at debug, and in the drain telemetry",
         %{camera: camera, config: config} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:cairn, :extractor, :drained]])
      on_exit(fn -> :telemetry.detach(ref) end)

      frags = mid_gop_frags(camera.id)

      log =
        at_debug_level(fn ->
          %{pid: pid, event: event} =
            run_keyframe_case(camera, config, drained: take(frags, [1, 2, 3]))

          finalize!(pid, event)
        end)

      assert log =~ "dropped 2 leading fragment(s) (2000ms)"
      # one line per clip, not one per dropped fragment
      assert log |> String.split("dropped 2 leading") |> length() == 2

      # And the same split, as numbers: one fragment kept of the three drained.
      assert_received {[:cairn, :extractor, :drained], ^ref, %{fragments: 1, skipped: 2}, _meta}
    end

    test "fragments skipped on the live path are reported the same way",
         %{camera: camera, config: config} do
      # The drain telemetry cannot carry these — it fired before they arrived —
      # so the debug line is the only report of a live-path skip, and it is
      # written when the keyframe finally opens the clip.
      frags = mid_gop_frags(camera.id)

      log =
        at_debug_level(fn ->
          %{pid: pid, event: event} =
            run_keyframe_case(camera, config, drained: [], live: take(frags, [1, 2, 3]))

          finalize!(pid, event)
        end)

      assert log =~ "dropped 2 leading fragment(s) (2000ms)"
      assert log |> String.split("dropped 2 leading") |> length() == 2
    end

    test "an event that never sees a keyframe says so once, at finalize",
         %{camera: camera, config: config} do
      # No keyframe ever arrives, so `open_media/1` never runs and the clip
      # holds its init segment alone. The other end of the report.
      frags = mid_gop_frags(camera.id)

      log =
        at_debug_level(fn ->
          %{pid: pid, event: event} =
            run_keyframe_case(camera, config, drained: take(frags, [1, 2]))

          assert %{fragments: 0, started?: false} = :sys.get_state(pid)
          finalize!(pid, event)
        end)

      assert log =~ "dropped 2 leading fragment(s) (2000ms)"
      assert log |> String.split("dropped 2 leading") |> length() == 2
    end

    # The shape this guards is the shipped default's, not a contrivance: a 5 s
    # ring against a 10 s GOP drops the whole drained pre-roll, and an event
    # that closes before the next keyframe leaves a file holding its init
    # segment alone. Announcing that `:event_clip_ready` put a `<video>` in
    # front of a file with no frames in it, and sent a snapshot after a frame
    # that does not exist.
    test "an event that never sees a keyframe is announced failed, not ready",
         %{camera: camera, config: config} do
      frags = mid_gop_frags(camera.id)
      test_pid = self()

      %{path: path, pid: pid, event: event} =
        run_keyframe_case(camera, %{config | remux_clips: true},
          drained: take(frags, [1, 2]),
          snapshot_fun: fn row, _cfg -> send(test_pid, {:snapshot_requested, row.id}) end,
          # Nothing may reach ffmpeg: there is nothing to rebase, and a remux of
          # an init segment either fails or writes a 0-duration mp4 over it.
          remux_fun: fn _path ->
            send(test_pid, :remux_ran)
            :error
          end
        )

      assert %{fragments: 0, started?: false} = :sys.get_state(pid)

      log = capture_log(fn -> finalize!(pid, event) end)
      assert log =~ "no keyframe arrived before the event closed"

      event_id = event.id
      camera_id = camera.id

      assert_receive {:event_clip_failed,
                      %EventArtifact{
                        event_id: ^event_id,
                        camera_id: ^camera_id,
                        path: nil,
                        bytes: nil,
                        reason: :no_keyframe
                      }}

      refute_received {:event_clip_ready, %EventArtifact{event_id: ^event_id}}
      refute_received :remux_ran
      # `:event_clip_failed` is terminal: no frame to cut a snapshot from
      refute_received {:snapshot_requested, ^event_id}

      # A box was cast in, so a sidecar would have been written had this gone
      # down the ready path — and it would have been a file whose anchor can
      # place nothing, both halves being empty.
      refute File.exists?(Cairn.DataDir.trackpath_for_clip(path))

      # The row is closed `partial` over the file that is really there: not
      # `finalized`, which claims a clip, and not deleted, which would leave the
      # row naming a file boot reconciliation then deletes the row for.
      row = Events.get(event_id)
      assert row.status == :partial
      assert row.ended_at != nil
      assert row.bytes == File.stat!(path).size
      assert row.bytes > 0

      # what those bytes are: the init segment, no fragment behind it
      assert {_d, [{:init, _}]} = Demuxer.push(Demuxer.new("check"), File.read!(path))
    end

    test "a keyframe that lands just before finalize leaves the ready path intact",
         %{camera: camera, config: config} do
      # The near miss: the same all-dropped drain, and fragment 3 arriving with
      # the event still open. One fragment is a clip.
      frags = mid_gop_frags(camera.id)
      test_pid = self()

      %{path: path, pid: pid, event: event} =
        run_keyframe_case(camera, config,
          drained: take(frags, [1, 2]),
          live: take(frags, [3]),
          snapshot_fun: fn row, _cfg -> send(test_pid, {:snapshot_requested, row.id}) end
        )

      assert %{fragments: 1, started?: true} = :sys.get_state(pid)

      finalize!(pid, event)

      event_id = event.id
      assert_receive {:event_clip_ready, %EventArtifact{event_id: ^event_id, reason: nil}}
      refute_received {:event_clip_failed, %EventArtifact{event_id: ^event_id}}
      assert_received {:snapshot_requested, ^event_id}

      assert %{status: :finalized} = Events.get(event_id)
      assert File.exists?(Cairn.DataDir.trackpath_for_clip(path))
      assert sidecar!(path)["anchor"]["live_media_ms"] == 1_000
    end

    # The suite runs at `:warning`, and `capture_log`'s own `:level` cannot go
    # under the primary level — it filters what a handler keeps, not what
    # `Logger` emits. This module is `async: false`, so it has the sync phase
    # to itself and nothing else can see the raised level.
    defp at_debug_level(fun) do
      previous = Logger.level()
      Logger.configure(level: :debug)

      try do
        capture_log(fun)
      after
        Logger.configure(level: previous)
      end
    end

    @mid_gop_fixture "test/support/fixtures/media/testsrc_gop3.fmp4"

    # Re-inits the camera's ring from the mid-GOP fixture and answers its
    # fragments. `put_init/5` clears the ring, so this also drops whatever the
    # outer setup put there; both are casts to the same GenServer, so the
    # fragments a caller puts next cannot overtake it.
    defp mid_gop_frags(camera_id) do
      {_d, events} = Demuxer.push(Demuxer.new(camera_id), File.read!(@mid_gop_fixture))
      [{:init, init} | rest] = events

      RingBuffer.put_init(camera_id, init.data, init.codec, init.timescale, Cairn.ULID.generate())

      for {:fragment, f} <- rest, do: f
    end

    defp take(frags, indexes), do: Enum.map(indexes, &Enum.at(frags, &1))

    # Fills the ring with `:drained`, starts an extractor over it, then feeds
    # `:live` and waits for the writer to settle. Returns the live pid so a
    # caller can read `fragments`/`skipped_fragments` before finalizing —
    # which is the assertion in most of these.
    defp run_keyframe_case(camera, config, opts) do
      drained = Keyword.fetch!(opts, :drained)
      live = Keyword.get(opts, :live, [])
      Enum.each(drained, &RingBuffer.put_fragment(camera.id, &1))

      event = new_event(camera)

      pid =
        start_supervised!(
          {EventExtractor,
           [
             camera: camera,
             event: event,
             config: config,
             snapshot_fun: Keyword.get(opts, :snapshot_fun, fn _row, _cfg -> :ok end)
           ] ++ Keyword.take(opts, [:remux_fun])},
          id: {:extractor, event.id}
        )

      assert %{status: :active, path: path} = wait_row(event.id)

      # A system message only comes back once the continue has returned, so
      # the drained fragments are all written (or all skipped) by here and the
      # live ones below cannot be confused with them.
      opened = :sys.get_state(pid).fragments
      Enum.each(live, &RingBuffer.put_fragment(camera.id, &1))
      wait_until(fn -> :sys.get_state(pid).fragments >= opened end)
      if live != [], do: wait_until(fn -> :sys.get_state(pid).started? end)

      # One box, so the sidecar is written at all: the anchor is what these
      # tests read, and an event with no boxes deliberately writes no file.
      GenServer.cast(
        pid,
        {:track_boxes, %{t_ms: 0, boxes: [{"obj-a", "person", [0.1, 0.2, 0.3, 0.4], false}]}}
      )

      %{path: path, pid: pid, event: event}
    end

    defp finalize!(pid, event) do
      ref = Process.monitor(pid)
      EventExtractor.finalize(pid, %{event | ended_at: DateTime.utc_now(), status: :finalized})
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
    end

    defp probe(path, entries) do
      {out, 0} =
        System.cmd("ffprobe", ~w(-v error -show_entries #{entries} -of csv=p=0) ++ [path])

      out |> String.trim() |> String.split(",") |> Enum.map(&elem(Float.parse(&1), 0))
    end
  end

  # Scoped to one camera: the `"events"` topic is global and a leftover timer
  # in another test's camera tracker can drop a foreign `event_ended` into this
  # mailbox between the two messages an ordering assertion is comparing.
  defp next_lifecycle(camera_id, timeout \\ 2_000) do
    receive do
      {kind, %Event{camera_id: ^camera_id}} = msg when kind in @lifecycle_kinds -> msg
      {kind, %EventArtifact{camera_id: ^camera_id}} = msg when kind in @artifact_kinds -> msg
    after
      timeout -> flunk("no event lifecycle message for #{camera_id} within #{timeout}ms")
    end
  end

  # No artifact kind was broadcast. The canary goes FIRST and is waited for:
  # it travels the same topic through the same `EventArtifact.broadcast/2`, so
  # a subscription that silently stopped working cannot make the refutes
  # vacuous, and anything a producer sent before now is already ahead of it in
  # this mailbox — which makes the refutes "nothing arrived up to this point"
  # rather than "nothing has arrived yet", even if a producer later grows an
  # async step.
  defp refute_artifacts(camera_id) do
    EventArtifact.broadcast(:event_clip_ready, %EventArtifact{
      event_id: "canary",
      camera_id: camera_id,
      path: "/canary.mp4",
      bytes: 1
    })

    assert_receive {:event_clip_ready, %EventArtifact{event_id: "canary"}}

    Enum.each(@artifact_kinds, fn kind ->
      refute_received {^kind, %EventArtifact{camera_id: ^camera_id}}
    end)
  end

  # Flunks rather than answering `nil`: every caller today pattern-matches
  # `%{status: ...}` and so would fail anyway, but a future `assert wait_row(id)
  # != x` would silently pass on the exhausted case.
  defp wait_row(id, attempts \\ 100) do
    case Events.get(id) do
      nil when attempts > 0 ->
        Process.sleep(10)
        wait_row(id, attempts - 1)

      nil ->
        flunk("no index row for event #{id} within 1s")

      row ->
        row
    end
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
