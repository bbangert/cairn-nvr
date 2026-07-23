defmodule Cairn.EventExtractorTest do
  use Cairn.DataCase, async: false

  alias Cairn.Config.Camera
  alias Cairn.{Config, Event, EventExtractor, Events, MP4.Demuxer, Reconciler, RingBuffer}

  @fixture "test/support/fixtures/media/testsrc.fmp4"

  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_ex_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    camera_id = "ex_#{System.unique_integer([:positive])}"
    camera = %Camera{id: camera_id, rtsp_url: "rtsp://h/1"}
    config = %Config{data_dir: dir, udp_base_port: 17_000, udp_port_range: 10}

    start_supervised!({RingBuffer, camera_id: camera_id, pre_window_seconds: 60})

    {init_meta, frags} = fixture_events(camera_id)
    RingBuffer.put_init(camera_id, init_meta.data, init_meta.codec, init_meta.timescale)

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
