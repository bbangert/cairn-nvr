defmodule Cairn.EventExtractorTest do
  use Cairn.DataCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Cairn.{
    Config,
    Event,
    EventArtifact,
    EventExtractor,
    Events,
    MP4.Demuxer,
    Reconciler,
    RingBuffer
  }

  alias Cairn.Config.Camera

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

  # The point of the artifact kinds: `event_ended` is the detection window
  # closing, `event_clip_ready` is the file becoming fetchable, and a consumer
  # must never be handed them the other way round.
  test "the clip is announced ready after event_ended, carrying its post-remux size",
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
    # exactly what `DetectionAggregator.maybe_finalize/4` does, in its order
    Event.broadcast(:event_ended, finalized)
    EventExtractor.finalize(pid, finalized)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    event_id = event.id
    camera_id = camera.id

    assert {:event_ended, %Event{id: ^event_id}} = next_lifecycle()

    assert {:event_clip_ready,
            %EventArtifact{
              event_id: ^event_id,
              camera_id: ^camera_id,
              path: ^path,
              reason: nil
            } = clip} = next_lifecycle()

    # the size announced is the remuxed file's, not the bytes the writer
    # streamed: a client sizing a download off it would be lied to otherwise
    assert clip.bytes == File.stat!(path).size
    refute clip.bytes == written
    assert Events.get(event_id).bytes == clip.bytes
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

  defp next_lifecycle(timeout \\ 2_000) do
    receive do
      {kind, _payload} = msg when kind in @lifecycle_kinds -> msg
    after
      timeout -> flunk("no event lifecycle message within #{timeout}ms")
    end
  end

  # No artifact kind was broadcast — with a canary afterwards, so a subscription
  # that silently stopped working cannot make this pass by default.
  defp refute_artifacts(camera_id) do
    Enum.each(@artifact_kinds, fn kind -> refute_received {^kind, _} end)

    EventArtifact.broadcast(:event_clip_ready, %EventArtifact{
      event_id: "canary",
      camera_id: camera_id,
      path: "/canary.mp4",
      bytes: 1
    })

    assert_receive {:event_clip_ready, %EventArtifact{event_id: "canary"}}
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
