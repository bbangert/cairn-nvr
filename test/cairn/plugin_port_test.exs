defmodule Cairn.PluginPortTest do
  # async: false — these tests share the "events" PubSub topic and capture_log
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cairn.Config.Camera
  alias Cairn.{DetectionAggregator, Event, Observation, PluginPort, StreamEpochs}

  @mock Path.absname("priv/plugins/mock/mock_plugin.exs")
  @timeline Path.absname("test/support/fixtures/timelines/person_walkthrough.json")

  defp camera(id) do
    %Camera{
      id: id,
      rtsp_url: "rtsp://h/1",
      plugin: {:inline, ["elixir", @mock]},
      min_score: %{"default" => 0.5}
    }
  end

  defp config, do: %Cairn.Config{data_dir: "tmp/plugin_port_test", udp_base_port: 19_100}

  # Each line is a printf *argument*, never the format string: a `%` or a `\`
  # in a payload would otherwise change the line's shape. Payloads must
  # contain no single quotes.
  defp printf(lines), do: "printf '%s\\n' " <> Enum.map_join(lines, " ", &"'#{&1}'")

  defp det_line(pts, dets), do: ~s({"pts": #{pts}, "dets": [#{Enum.join(dets, ", ")}]})

  defp det(label, score, bbox) do
    ~s({"label": "#{label}", "score": #{score}, "bbox": #{bbox}})
  end

  defp v1_line(camera_id, epoch, sequence, objects) do
    Jason.encode!(%{
      "spec" => "cairn.plugin",
      "version" => 1,
      "type" => "frame.objects",
      "camera_id" => camera_id,
      "stream_epoch" => epoch,
      "sequence" => sequence,
      "frame" => %{"pts" => sequence * 3_000, "observed_at" => "2026-07-26T12:00:00Z"},
      "objects" => objects
    })
  end

  defp object(label, score) do
    %{"label" => label, "score" => score, "bbox" => [0.1, 0.1, 0.2, 0.4]}
  end

  # A plugin that reads its stdin and appends every control line to a file:
  # the only way to see what the port actually wrote.
  defp stdin_recorder do
    path =
      Path.join(System.tmp_dir!(), "cairn_control_#{System.unique_integer([:positive])}.ndjson")

    on_exit(fn -> File.rm(path) end)
    {path, ~s(while IFS= read -r line; do printf '%s\\n' "$line" >> #{path}; done)}
  end

  # Flunks rather than returning what it has: a "the port wrote it" assertion
  # must not pass on a timeout.
  defp await_control(path, count, attempts \\ 200) do
    lines =
      case File.read(path) do
        {:ok, contents} ->
          contents |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

        {:error, _} ->
          []
      end

    cond do
      length(lines) >= count -> lines
      attempts == 0 -> flunk("plugin received #{length(lines)} control lines, wanted #{count}")
      true -> Process.sleep(25) && await_control(path, count, attempts - 1)
    end
  end

  test "build_argv appends contract arguments" do
    argv = PluginPort.build_argv(camera("c"), 17_002)

    assert ["elixir", @mock, "--camera-id", "c", "--udp-port", "17002", "--min-score-json", json] =
             argv

    assert Jason.decode!(json) == %{"default" => 0.5}
  end

  test "mock plugin timeline drives the aggregator through a full Port" do
    id = "plug_#{System.unique_integer([:positive])}"
    test_pid = self()

    # the mock speaks v1: it stamps its lines with the epoch the port hands it
    # on stdin, and the port drops anything from another epoch
    StreamEpochs.new_epoch(id, :started)

    agg =
      start_supervised!(
        {DetectionAggregator,
         name: nil,
         start_extractor: fn _camera, _event ->
           {:ok, spawn(fn -> Process.sleep(:infinity) end)}
         end,
         finalize_extractor: fn _pid, event -> send(test_pid, {:finalized, event}) end}
      )

    Event.subscribe()

    command =
      "elixir #{@mock} --camera-id #{id} --udp-port 19100 " <>
        "--min-score-json '{}' --timeline #{@timeline}; exec sleep 30"

    start_supervised!(
      {PluginPort,
       camera: camera(id), config: config(), index: 0, command: command, aggregator: agg}
    )

    assert_receive {:event_started, %Event{camera_id: ^id} = event}, 5_000
    assert [%{label: "person"}] = event.labels

    # third batch has person (0.93, passes) + cat (0.4, filtered by 0.5 default)
    assert_receive {:event_updated, %Event{camera_id: ^id}}, 5_000
    assert_receive {:event_updated, %Event{camera_id: ^id} = updated}, 5_000
    assert Map.keys(updated.max_scores) == ["person"]
  end

  test "malformed lines are dropped without crashing" do
    id = "plug_#{System.unique_integer([:positive])}"

    agg =
      start_supervised!(
        {DetectionAggregator,
         name: nil,
         start_extractor: fn _c, _e -> {:ok, spawn(fn -> Process.sleep(:infinity) end)} end}
      )

    Event.subscribe()

    command =
      printf([
        "garbage",
        ~s({"nope": true}),
        det_line(1, [det("person", "0.9", "[0, 0, 1, 1]")])
      ]) <> "; exec sleep 30"

    pid =
      start_supervised!(
        {PluginPort,
         camera: camera(id), config: config(), index: 0, command: command, aggregator: agg}
      )

    assert_receive {:event_started, %Cairn.Event{camera_id: ^id}}, 5_000
    assert %PluginPort{} = :sys.get_state(pid)
  end

  test "invalid dets are dropped individually and the valid ones still forward" do
    id = "plug_#{System.unique_integer([:positive])}"

    malformed =
      det_line(1, [
        det("person", "0.9", "[0, 0, 1]"),
        det("person", ~s("0.9"), "[0, 0, 1, 1]"),
        det("person", "5.0", "[0, 0, 1, 1]"),
        det("person", "0.9", "[-0.5, 0, 1, 1]"),
        det("person", "0.9", "[0, 0, 2, 2]"),
        det("cat", "0.8", "[0.1, 0.1, 0.2, 0.2]")
      ])

    bad_pts = det_line(~s("later"), [det("person", "0.9", "[0, 0, 1, 1]")])
    good = det_line(3, [det("person", "0.9", "[0, 0, 1, 1]")])

    command = printf([malformed, bad_pts, good]) <> "; exec sleep 30"

    pid =
      start_supervised!(
        {PluginPort,
         camera: camera(id), config: config(), index: 0, command: command, aggregator: self()}
      )

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^id}, _windows, %Observation{pts: 1} = obs}},
                   5_000

    assert [%{label: "cat", score: 0.8, bbox: [0.1, 0.1, 0.2, 0.2]}] = obs.objects

    # the non-numeric pts line is dropped whole, so the next cast is the last line
    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^id}, _windows, %Observation{pts: 3} = good}},
                   5_000

    assert [%{label: "person", score: 0.9, bbox: [0, 0, 1, 1]}] = good.objects
    assert %PluginPort{} = :sys.get_state(pid)
  end

  test "a malformed bbox never reaches the tracker through the aggregator" do
    id = "plug_#{System.unique_integer([:positive])}"

    agg =
      start_supervised!(
        {DetectionAggregator,
         name: nil,
         start_extractor: fn _c, _e -> {:ok, spawn(fn -> Process.sleep(:infinity) end)} end}
      )

    Event.subscribe()

    # a 3-element bbox used to be tracked, then crash Tracker.iou/2 on the
    # next same-label batch, taking every camera's event tracking with it
    command =
      printf([
        det_line(1, [det("person", "0.9", "[0, 0, 1]")]),
        det_line(2, [det("person", "0.9", "[0, 0, 1, 1]")]),
        det_line(3, [det("person", "0.9", "[0.01, 0, 0.99, 1]")])
      ]) <> "; exec sleep 30"

    pid =
      start_supervised!(
        {PluginPort,
         camera: camera(id), config: config(), index: 0, command: command, aggregator: agg}
      )

    assert_receive {:event_started, %Event{camera_id: ^id} = event}, 5_000
    assert [%{label: "person"}] = event.labels

    # only reachable if the batch *after* the poisoned one was tracked: pre-fix
    # :event_started fired on line 1 and the crash landed on line 2
    assert_receive {:event_updated, %Event{camera_id: ^id}}, 5_000
    # a round-trip through each: the aggregator survived the poisoned batch and
    # the port survived forwarding it
    assert %{} = :sys.get_state(agg)
    assert %PluginPort{} = :sys.get_state(pid)
  end

  test "an over-long line is skipped and the next line still parses" do
    id = "plug_#{System.unique_integer([:positive])}"
    long = String.duplicate("x", 70_000)

    command =
      printf([long, det_line(7, [det("person", "0.9", "[0, 0, 1, 1]")])]) <> "; exec sleep 30"

    pid =
      start_supervised!(
        {PluginPort,
         camera: camera(id), config: config(), index: 0, command: command, aggregator: self()}
      )

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^id}, _windows, %Observation{pts: 7}}},
                   5_000

    assert %PluginPort{} = :sys.get_state(pid)
  end

  test "one line of many invalid dets emits at most one warning" do
    id = "plug_#{System.unique_integer([:positive])}"

    # 60 invalid dets on one line: pre-fix this was one Logger call per drop
    flood = det_line(1, List.duplicate(det("person", "0.9", "[0, 0, 1]"), 60))
    good = det_line(2, [det("person", "0.9", "[0, 0, 1, 1]")])
    command = printf([flood, good]) <> "; exec sleep 30"

    log =
      capture_log(fn ->
        start_supervised!(
          {PluginPort,
           camera: camera(id), config: config(), index: 0, command: command, aggregator: self()}
        )

        # ordered after the flood: the port handles lines in order
        assert_receive {:"$gen_cast",
                        {:detections, %Camera{id: ^id}, _windows, %Observation{pts: 2}}},
                       5_000
      end)

    assert length(Regex.scan(~r/dropped lines\/dets/, log)) == 1
    assert log =~ "invalid_det ×60 (60 total)"
  end

  test "the plugin is told the current epoch on spawn and every change after" do
    id = "plug_ctl_#{System.unique_integer([:positive])}"
    first = StreamEpochs.new_epoch(id, :started)
    {path, command} = stdin_recorder()

    start_supervised!(
      {PluginPort,
       camera: camera(id), config: config(), index: 0, command: command, aggregator: self()}
    )

    # pulled from ETS at spawn: no broadcast is involved, so nothing is lost
    # when the plugin starts after the stream did
    assert [started] = await_control(path, 1)

    assert %{
             "spec" => "cairn.plugin",
             "version" => 1,
             "type" => "stream.started",
             "camera_id" => ^id,
             "stream_epoch" => ^first,
             "rtp" => %{"clock_rate" => 90_000}
           } = started

    # a new epoch ends the one the plugin knows about, then starts the new one
    second = StreamEpochs.new_epoch(id, :source_lost)
    assert [_, ended, restarted] = await_control(path, 3)

    assert %{"type" => "stream.ended", "stream_epoch" => ^first, "reason" => "source_lost"} =
             ended

    assert %{"type" => "stream.started", "stream_epoch" => ^second} = restarted

    # :camera_stopped mints an epoch nothing streams under: it ends the live
    # stream and starts nothing
    StreamEpochs.new_epoch(id, :camera_stopped)
    assert [_, _, _, stopped] = await_control(path, 4)

    assert %{"type" => "stream.ended", "stream_epoch" => ^second, "reason" => "camera_stopped"} =
             stopped

    Process.sleep(50)
    assert length(await_control(path, 4)) == 4
  end

  test "a plugin that never reads stdin costs drops, not the port" do
    id = "plug_deaf_#{System.unique_integer([:positive])}"
    StreamEpochs.new_epoch(id, :started)

    pid =
      start_supervised!({
        PluginPort,
        # `exec` so the port's SIGTERM reaches the sleep itself: a plain
        # `sleep` is a child of the sh the port kills, and would outlive the
        # test holding its inherited stdout open
        camera: camera(id),
        config: config(),
        index: 0,
        command: "exec sleep 60",
        aggregator: self()
      })

    # far more than the pipe buffer plus the port's busy watermark, so the
    # writes must go through the :nosuspend path that drops instead of blocking
    capture_log(fn -> for _ <- 1..1_000, do: StreamEpochs.new_epoch(id, :stall_bounce) end)

    state = :sys.get_state(pid)
    assert %PluginPort{} = state
    # the plugin never read its stdin, so the writes were dropped, not queued
    assert state.drops[:control_stdin_busy] > 0
    # the port kept up: the last epoch minted is the one it recorded
    assert {epoch, :live} = state.epoch
    assert {:ok, ^epoch} = StreamEpochs.current(id)
  end

  test "stale-epoch lines are dropped and sequence gaps are counted" do
    id = "plug_seq_#{System.unique_integer([:positive])}"
    epoch = StreamEpochs.new_epoch(id, :started)
    test_pid = self()

    handler = "seq_gap_#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:cairn, :plugin, :sequence_gap],
      fn _event, measurements, metadata, _ -> send(test_pid, {:gap, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    command =
      printf([
        v1_line(id, epoch, 1, [object("person", 0.9)]),
        v1_line(id, "01OTHEREPOCH0000000000000", 2, [object("person", 0.9)]),
        v1_line(id, epoch, 5, [object("person", 0.9)])
      ]) <> "; exec sleep 30"

    pid =
      start_supervised!(
        {PluginPort,
         camera: camera(id), config: config(), index: 0, command: command, aggregator: self()}
      )

    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^id}, _w, %Observation{sequence: 1}}},
                   5_000

    # the stale line never reaches the aggregator; the next good one does
    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^id}, _w, %Observation{sequence: 5}}},
                   5_000

    # sequences 2..4 (the stale line's number included) are a gap of 3
    assert_receive {:gap, %{count: 3}, %{camera_id: ^id}}, 5_000
    assert :sys.get_state(pid).drops == %{stale_epoch: 1, sequence_gap: 3}
  end

  test "hello and status reach the log and CameraStatus" do
    id = "plug_hello_#{System.unique_integer([:positive])}"

    hello =
      Jason.encode!(%{
        "spec" => "cairn.plugin",
        "version" => 1,
        "type" => "plugin.hello",
        "hello" => %{
          "name" => "fake-detect",
          "version" => "9.9",
          "supported_versions" => [2],
          "capabilities" => %{"object_tracking" => true}
        }
      })

    status =
      Jason.encode!(%{
        "spec" => "cairn.plugin",
        "version" => 1,
        "type" => "plugin.status",
        "status" => %{"state" => "ready", "detail" => "model loaded"}
      })

    Cairn.CameraStatus.subscribe()
    on_exit(fn -> Cairn.CameraStatus.prune(Map.keys(Cairn.CameraStatus.all()) -- [id]) end)

    # the hello line is info, and the suite runs at :warning
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log(fn ->
        pid =
          start_supervised!(
            {PluginPort,
             camera: camera(id),
             config: config(),
             index: 0,
             command: printf([hello, status]) <> "; exec sleep 30",
             aggregator: self()}
          )

        assert_receive {:camera_status, ^id, info}, 5_000
        assert info.plugin_status == %{"state" => "ready", "detail" => "model loaded"}

        assert %{"name" => "fake-detect"} = :sys.get_state(pid).plugin
      end)

    assert log =~ "plugin hello — fake-detect 9.9"
    assert log =~ "does not list protocol 1 in supported_versions"
  end

  test "plugin exit triggers backoff respawn" do
    id = "plug_#{System.unique_integer([:positive])}"

    agg =
      start_supervised!(
        {DetectionAggregator,
         name: nil,
         start_extractor: fn _c, _e -> {:ok, spawn(fn -> Process.sleep(:infinity) end)} end}
      )

    Event.subscribe()

    # exits immediately after one valid line; respawn emits it again
    command = printf([det_line(1, [det("person", "0.9", "[0, 0, 1, 1]")])])

    start_supervised!(
      {PluginPort,
       camera: camera(id),
       config: config(),
       index: 0,
       command: command,
       aggregator: agg,
       backoff_min_ms: 50,
       backoff_max_ms: 100}
    )

    assert_receive {:event_started, %Cairn.Event{camera_id: ^id}}, 5_000
    assert_receive {:event_updated, %Cairn.Event{camera_id: ^id}}, 5_000
  end
end
