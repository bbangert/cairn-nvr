defmodule Cairn.PluginGroupPortTest do
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
    ~s({"camera_id": "#{camera_id}", "pts": #{pts}, ) <>
      ~s("dets": [{"label": "person", "score": #{score}, "bbox": [0,0,1,1]}]})
  end

  defp printf(lines), do: "printf '#{Enum.join(lines, "\\n")}\\n'"

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

    command = printf([det_line(a.id, 1, 0.9), det_line(b.id, 2, 0.8)]) <> "; sleep 30"
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
    command = printf([det_line(b.id, 1, 0.7), det_line(a.id, 2, 0.7)]) <> "; sleep 30"
    start_group_port([a, b], command: command, aggregator: agg)

    a_id = a.id
    assert_receive {:event_started, %Event{camera_id: ^a_id}}, 5_000
    refute_receive {:event_started, %Event{camera_id: _}}, 200
  end

  test "unknown and missing camera_id lines are dropped without crashing" do
    a = camera("gp_drop_#{System.unique_integer([:positive])}")

    command =
      printf([
        det_line("not_a_member", 1, 0.9),
        ~s({"pts": 2, "dets": []}),
        "garbage",
        det_line(a.id, 3, 0.9)
      ]) <> "; sleep 30"

    pid = start_group_port([a], command: command, aggregator: self())

    a_id = a.id
    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, _windows, 3, _dets}}, 5_000
    assert Process.alive?(pid)
  end

  test "over-long lines are skipped and the next line still routes" do
    a = camera("gp_long_#{System.unique_integer([:positive])}")
    long = String.duplicate("x", 9_000)

    command = printf([long, det_line(a.id, 7, 0.9)]) <> "; sleep 30"
    pid = start_group_port([a], command: command, aggregator: self())

    a_id = a.id
    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, _windows, 7, _dets}}, 5_000
    assert Process.alive?(pid)
  end

  test "refresh swaps the routes without restarting the plugin process" do
    a = camera("gp_refresh_#{System.unique_integer([:positive])}")

    command =
      printf([det_line(a.id, 1, 0.9)]) <>
        "; sleep 1; " <> printf([det_line(a.id, 2, 0.9)]) <> "; sleep 30"

    pid = start_group_port([a], command: command, aggregator: self())
    a_id = a.id

    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, windows, 1, _dets}}, 5_000
    assert windows.post == 10
    os_pid = :sys.get_state(pid).os_pid

    # the group is unchanged; only a camera field the argv never carried moved
    widened = %Camera{a | post_window_seconds: 42}
    :ok = PluginGroupPort.refresh(pid, group([widened]), config([widened]))

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^a_id, post_window_seconds: 42}, %{post: 42}, 2,
                     _dets}},
                   5_000

    assert Process.alive?(pid)
    assert :sys.get_state(pid).os_pid == os_pid
  end

  test "unroutable lines are counted but only logged periodically" do
    a = camera("gp_flood_#{System.unique_integer([:positive])}")
    strangers = for pts <- 1..5, do: det_line("stranger", pts, 0.9)
    command = printf(strangers ++ [det_line(a.id, 99, 0.9)]) <> "; sleep 30"

    log =
      capture_log(fn ->
        start_group_port([a], command: command, aggregator: self())
        # ordered after all five drops: the port handles lines in order
        assert_receive {:"$gen_cast", {:detections, _cam, _windows, 99, _dets}}, 5_000
      end)

    assert length(Regex.scan(~r/line for unknown camera/, log)) == 1
    assert log =~ ~s|unknown camera "stranger", dropped (1 so far)|
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
