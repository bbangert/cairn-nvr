defmodule Cairn.PluginGroupPortTest do
  # async: false — these tests share the "events" PubSub topic and capture_log
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cairn.Config.Camera
  alias Cairn.Config.PluginGroup
  alias Cairn.{DetectionAggregator, Event, PluginGroupPort}

  defp camera(id, opts \\ []) do
    %Camera{
      id: id,
      rtsp_url: "rtsp://h/#{id}",
      plugin: {:group, "detect"},
      min_score: Keyword.get(opts, :min_score, %{"default" => 0.5}),
      post_window_seconds: Keyword.get(opts, :post_window_seconds)
    }
  end

  defp group(cameras) do
    members =
      cameras
      |> Enum.with_index()
      |> Enum.map(fn {cam, index} ->
        %{id: cam.id, udp_port: 19_200 + 4 * index, min_score: cam.min_score}
      end)

    %PluginGroup{name: "detect", command: ["./detect"], members: members}
  end

  defp config(cameras) do
    %Cairn.Config{
      data_dir: "tmp/plugin_group_port_test",
      udp_base_port: 19_200,
      post_window_seconds: 10,
      cameras: cameras
    }
  end

  defp start_group_port(cameras, opts) do
    start_supervised!(
      {PluginGroupPort, [group: group(cameras), config: config(cameras)] |> Keyword.merge(opts)}
    )
  end

  defp det_line(camera_id, pts, score) do
    line(camera_id, pts, [det("person", score, "[0,0,1,1]")])
  end

  defp line(camera_id, pts, dets) do
    ~s({"camera_id": "#{camera_id}", "pts": #{pts}, "dets": [#{Enum.join(dets, ", ")}]})
  end

  defp det(label, score, bbox) do
    ~s({"label": "#{label}", "score": #{score}, "bbox": #{bbox}})
  end

  # A valid line padded with an ignored field to exactly `bytes` bytes, for the
  # boundaries of the {:line, 65_536} chunking.
  defp padded_line(camera_id, pts, bytes) do
    head = String.trim_trailing(det_line(camera_id, pts, 0.9), "}") <> ~s(, "pad": ")
    tail = ~s("})
    head <> String.duplicate("x", bytes - byte_size(head) - byte_size(tail)) <> tail
  end

  # Each line is a printf *argument*, never the format string: a `%` or a `\`
  # in a payload would otherwise change the line's shape. Payloads must
  # contain no single quotes.
  defp printf(lines), do: "printf '%s\\n' " <> Enum.map_join(lines, " ", &"'#{&1}'")

  test "build_argv passes the members as --cameras-json" do
    cams = [camera("g_a"), camera("g_b", min_score: %{"default" => 0.9})]

    assert ["./detect", "--cameras-json", json] = PluginGroupPort.build_argv(group(cams))

    assert Jason.decode!(json) == [
             %{"id" => "g_a", "udp_port" => 19_200, "min_score" => %{"default" => 0.5}},
             %{"id" => "g_b", "udp_port" => 19_204, "min_score" => %{"default" => 0.9}}
           ]
  end

  test "lines are routed to the camera named by camera_id" do
    a = camera("gp_a_#{System.unique_integer([:positive])}")
    b = camera("gp_b_#{System.unique_integer([:positive])}", post_window_seconds: 42)

    command = printf([det_line(a.id, 1, 0.9), det_line(b.id, 2, 0.8)]) <> "; exec sleep 30"
    start_group_port([a, b], command: command, aggregator: self())

    a_id = a.id
    b_id = b.id

    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, windows_a, 1, dets_a}}, 5_000
    assert windows_a == %{pre: 5, post: 10, max: 300}
    assert [%{label: "person", score: 0.9}] = dets_a

    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^b_id}, windows_b, 2, _dets}}, 5_000
    assert windows_b == %{pre: 5, post: 42, max: 300}
  end

  test "each camera's own min_score applies through the aggregator" do
    a = camera("gp_low_#{System.unique_integer([:positive])}")
    b = camera("gp_high_#{System.unique_integer([:positive])}", min_score: %{"default" => 0.95})

    agg =
      start_supervised!(
        {DetectionAggregator,
         name: nil,
         start_extractor: fn _c, _e -> {:ok, spawn(fn -> Process.sleep(:infinity) end)} end}
      )

    Event.subscribe()

    # 0.7 clears cam a's 0.5 floor and is filtered out for cam b's 0.95
    command = printf([det_line(b.id, 1, 0.7), det_line(a.id, 2, 0.7)]) <> "; exec sleep 30"
    start_group_port([a, b], command: command, aggregator: agg)

    a_id = a.id
    b_id = b.id
    assert_receive {:event_started, %Event{camera_id: ^a_id}}, 5_000
    # b's line precedes a's in the command, so a's arrival means b's was handled
    refute_receive {:event_started, %Event{camera_id: ^b_id}}, 500
  end

  test "unknown and missing camera_id lines are dropped without crashing" do
    a = camera("gp_drop_#{System.unique_integer([:positive])}")

    command =
      printf([
        det_line("not_a_member", 1, 0.9),
        ~s({"pts": 2, "dets": []}),
        "garbage",
        det_line(a.id, 3, 0.9)
      ]) <> "; exec sleep 30"

    pid = start_group_port([a], command: command, aggregator: self())

    a_id = a.id
    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, _windows, 3, _dets}}, 5_000
    assert Process.alive?(pid)
  end

  test "over-long lines are skipped and the next line still routes" do
    a = camera("gp_long_#{System.unique_integer([:positive])}")
    long = String.duplicate("x", 70_000)

    command = printf([long, det_line(a.id, 7, 0.9)]) <> "; exec sleep 30"
    pid = start_group_port([a], command: command, aggregator: self())

    a_id = a.id
    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, _windows, 7, _dets}}, 5_000
    assert Process.alive?(pid)
  end

  test "a line at exactly the 65_536-byte limit still routes" do
    a = camera("gp_65536_#{System.unique_integer([:positive])}")
    line = padded_line(a.id, 11, 65_536)
    assert byte_size(line) == 65_536

    # {:line, 65_536} delivers up to 65_536 bytes of line data as {:eol, _}
    # and only splits above that, so the limit itself is accepted
    command = printf([line]) <> "; exec sleep 30"
    pid = start_group_port([a], command: command, aggregator: self())

    a_id = a.id
    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, _windows, 11, dets}}, 5_000
    assert [%{label: "person"}] = dets
    assert Process.alive?(pid)
  end

  test "a line one byte over the limit is dropped and the next line still routes" do
    a = camera("gp_65537_#{System.unique_integer([:positive])}")
    over = padded_line(a.id, 12, 65_537)
    assert byte_size(over) == 65_537

    # delivered as {:noeol, 65_536} + {:eol, 1}: the one-byte remainder is what
    # has to clear skipping_long_line before line 13 arrives
    command = printf([over, det_line(a.id, 13, 0.9)]) <> "; exec sleep 30"
    pid = start_group_port([a], command: command, aggregator: self())

    a_id = a.id
    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, _windows, pts, _dets}}, 5_000
    assert pts == 13
    assert Process.alive?(pid)
  end

  test "invalid dets are dropped individually and the valid ones still route" do
    a = camera("gp_det_#{System.unique_integer([:positive])}")

    malformed =
      line(a.id, 1, [
        det("person", "0.9", "[0, 0, 1]"),
        det("person", ~s("0.9"), "[0, 0, 1, 1]"),
        det("person", "5.0", "[0, 0, 1, 1]"),
        det("person", "0.9", "[-0.5, 0, 1, 1]"),
        det("person", "0.9", "[0, 0, 2, 2]"),
        det("cat", "0.8", "[0.1, 0.1, 0.2, 0.2]")
      ])

    bad_pts = line(a.id, ~s("later"), [det("person", "0.9", "[0, 0, 1, 1]")])
    good = line(a.id, 3, [det("person", "0.9", "[0, 0, 1, 1]")])

    command = printf([malformed, bad_pts, good]) <> "; exec sleep 30"
    pid = start_group_port([a], command: command, aggregator: self())

    a_id = a.id
    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, _windows, 1, dets}}, 5_000
    assert dets == [%{label: "cat", score: 0.8, bbox: [0.1, 0.1, 0.2, 0.2]}]

    # the non-numeric pts line is dropped whole, so the next cast is the last line
    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, _windows, 3, good_dets}},
                   5_000

    assert good_dets == [%{label: "person", score: 0.9, bbox: [0, 0, 1, 1]}]
    assert Process.alive?(pid)
  end

  test "a malformed bbox never reaches the tracker through the aggregator" do
    a = camera("gp_bbox_#{System.unique_integer([:positive])}")

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
        line(a.id, 1, [det("person", "0.9", "[0, 0, 1]")]),
        line(a.id, 2, [det("person", "0.9", "[0, 0, 1, 1]")]),
        line(a.id, 3, [det("person", "0.9", "[0.01, 0, 0.99, 1]")])
      ]) <> "; exec sleep 30"

    ref = Process.monitor(agg)
    pid = start_group_port([a], command: command, aggregator: agg)

    a_id = a.id
    assert_receive {:event_started, %Event{camera_id: ^a_id}}, 5_000

    # only reachable if the batch *after* the poisoned one was tracked: pre-fix
    # :event_started fired on line 1 and the crash landed on line 2
    assert_receive {:event_updated, %Event{camera_id: ^a_id}}, 5_000
    refute_received {:DOWN, ^ref, :process, _, _}
    assert Process.alive?(agg)
    assert Process.alive?(pid)
  end

  test "refresh swaps the routes without restarting the plugin process" do
    a = camera("gp_refresh_#{System.unique_integer([:positive])}")

    # the second line has to arrive after the refresh cast is handled, so the
    # fake's window is wide and the cast is flushed synchronously below
    command =
      printf([det_line(a.id, 1, 0.9)]) <>
        "; sleep 5; " <> printf([det_line(a.id, 2, 0.9)]) <> "; exec sleep 30"

    pid = start_group_port([a], command: command, aggregator: self())
    a_id = a.id

    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, windows, 1, _dets}}, 5_000
    assert windows.post == 10
    os_pid = :sys.get_state(pid).os_pid

    # the group is unchanged; only a camera field the argv never carried moved
    widened = %Camera{a | post_window_seconds: 42}
    :ok = PluginGroupPort.refresh(pid, group([widened]), config([widened]))
    # flush the cast: it must be handled before the fake emits line 2
    :sys.get_state(pid)

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^a_id, post_window_seconds: 42}, %{post: 42}, 2,
                     _dets}},
                   10_000

    assert Process.alive?(pid)
    assert :sys.get_state(pid).os_pid == os_pid
  end

  test "unroutable lines are counted but only logged periodically" do
    a = camera("gp_flood_#{System.unique_integer([:positive])}")
    strangers = for pts <- 1..5, do: det_line("stranger", pts, 0.9)
    command = printf(strangers ++ [det_line(a.id, 99, 0.9)]) <> "; exec sleep 30"

    log =
      capture_log(fn ->
        start_group_port([a], command: command, aggregator: self())
        # ordered after all five drops: the port handles lines in order
        assert_receive {:"$gen_cast", {:detections, _cam, _windows, 99, _dets}}, 5_000
      end)

    assert length(Regex.scan(~r/dropped lines\/dets/, log)) == 1
    assert log =~ ~s|unknown_camera ×1 (1 total); latest unknown_camera: "stranger"|
  end

  test "plugin exit triggers backoff respawn" do
    a = camera("gp_exit_#{System.unique_integer([:positive])}")

    # exits after one line; the respawned process emits it again
    command = printf([det_line(a.id, 1, 0.9)])

    start_group_port([a],
      command: command,
      aggregator: self(),
      backoff_min_ms: 50,
      backoff_max_ms: 100
    )

    a_id = a.id
    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, _w, 1, _dets}}, 5_000
    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, _w, 1, _dets}}, 5_000
  end
end
