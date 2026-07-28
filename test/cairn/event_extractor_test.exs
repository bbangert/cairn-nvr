defmodule Cairn.EventExtractorTest do
  use Cairn.DataCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Cairn.{
    Config,
    DetectionAggregator,
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
    # remux off by default here so the fragment-level assertions below test the
    # writer itself; the remux behaviour has its own tests.
    config = %Config{
      data_dir: dir,
      udp_base_port: 17_000,
      udp_port_range: 10,
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
  # kicked off afterwards. The *aggregator's* ordering is pinned by the two
  # tests below and by the stub test in `DetectionAggregatorTest`.
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

  # B2: the guarantee end to end. The aggregator's own `maybe_finalize/4`
  # supplies the interleaving here — no stub extractor funs, a real extractor
  # doing a real close/remux/index/broadcast on the other side of the cast.
  test "a real aggregator finalizing a real extractor announces event_ended first",
       %{camera: camera, config: config, frags: frags} do
    test_pid = self()
    on_exit(fn -> EventCheckpoint.delete(camera.id) end)

    agg =
      start_supervised!({
        DetectionAggregator,
        # the real extractor; only its data_dir is pinned to this test's, and
        # the snapshot is stubbed so no ffmpeg runs. `finalize_extractor` is
        # left at its default — the real cast.
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
    DetectionAggregator.detections(agg, camera, @policy, observation(camera.id))

    assert {:event_started, %Event{id: event_id}} = next_lifecycle(camera.id)
    assert %{status: :active} = wait_row(event_id)

    # fire the post-window timer the aggregator armed, with its own token
    cam = :sys.get_state(agg).cameras[camera.id]
    send(agg, {:post_window, camera.id, event_id, cam.post_token})

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
      tracking: false,
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
    # row without file
    gone = new_event(camera)
    {:ok, _} = Events.create_active(gone, Path.join(config.data_dir, "nope.mp4"))

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

  # Scoped to one camera: the `"events"` topic is global and a leftover timer
  # in another test's aggregator can drop a foreign `event_ended` into this
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

  defp wait_row(id, attempts \\ 100) do
    case Events.get(id) do
      nil when attempts > 0 ->
        Process.sleep(10)
        wait_row(id, attempts - 1)

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
