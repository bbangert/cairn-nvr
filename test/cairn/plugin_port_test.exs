defmodule Cairn.PluginPortTest do
  # async: false — these tests share the "events" PubSub topic and capture_log
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cairn.Config.Camera
  alias Cairn.{DetectionAggregator, Event, PluginPort}

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

  test "build_argv appends contract arguments" do
    argv = PluginPort.build_argv(camera("c"), 17_002)

    assert ["elixir", @mock, "--camera-id", "c", "--udp-port", "17002", "--min-score-json", json] =
             argv

    assert Jason.decode!(json) == %{"default" => 0.5}
  end

  test "mock plugin timeline drives the aggregator through a full Port" do
    id = "plug_#{System.unique_integer([:positive])}"
    test_pid = self()

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

    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^id}, _windows, 1, dets}}, 5_000
    assert dets == [%{label: "cat", score: 0.8, bbox: [0.1, 0.1, 0.2, 0.2]}]

    # the non-numeric pts line is dropped whole, so the next cast is the last line
    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^id}, _windows, 3, good_dets}}, 5_000
    assert good_dets == [%{label: "person", score: 0.9, bbox: [0, 0, 1, 1]}]
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

    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^id}, _windows, 7, _dets}}, 5_000
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
        assert_receive {:"$gen_cast", {:detections, %Camera{id: ^id}, _windows, 2, _dets}}, 5_000
      end)

    assert length(Regex.scan(~r/dropped lines\/dets/, log)) == 1
    assert log =~ "invalid_det ×60 (60 total)"
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
