defmodule Cairn.PluginGroupPortTest do
  # async: false — these tests share the "events" PubSub topic and capture_log.
  # DataCase because they start real camera trackers, whose checkpoint restore
  # consults the event index.
  use Cairn.DataCase, async: false

  import ExUnit.CaptureLog

  alias Cairn.{CameraTracker, Event, Observation, PluginGroupPort, StreamEpochs}
  alias Cairn.Config.Camera
  alias Cairn.Config.PluginGroup

  defp camera(id, opts \\ []) do
    %Camera{
      id: id,
      rtsp_url: "rtsp://h/#{id}",
      plugin: {:group, "detect"},
      min_score: Keyword.get(opts, :min_score, %{"default" => 0.5}),
      post_window_seconds: Keyword.get(opts, :post_window_seconds)
    }
  end

  defp group(cameras, name \\ "detect") do
    members =
      cameras
      |> Enum.with_index()
      |> Enum.map(fn {cam, index} ->
        %{id: cam.id, udp_port: 19_200 + 4 * index, min_score: cam.min_score}
      end)

    %PluginGroup{name: name, command: ["./detect"], members: members}
  end

  defp config(cameras) do
    %Cairn.Config{
      data_dir: "tmp/plugin_group_port_test",
      udp_base_port: 19_200,
      post_window_seconds: 10,
      cameras: cameras
    }
  end

  # A group port registers under its group name, so a test that runs two of
  # them at once has to name them apart (and give the supervisor distinct ids).
  defp start_group_port(cameras, opts) do
    {id, opts} = Keyword.pop(opts, :id)
    {name, opts} = Keyword.pop(opts, :group_name, "detect")

    spec =
      {PluginGroupPort,
       [group: group(cameras, name), config: config(cameras)] |> Keyword.merge(opts)}

    if id, do: start_supervised!(spec, id: id), else: start_supervised!(spec)
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

  defp v1_line(camera_id, epoch, sequence, objects) do
    Jason.encode!(%{
      "spec" => "cairn.plugin",
      "version" => 1,
      "type" => "frame.objects",
      "camera_id" => camera_id,
      "stream_epoch" => epoch,
      "sequence" => sequence,
      # the port clamps an `observed_at` far from host time, so a line that is
      # not about clock skew has to carry a live one
      "frame" => %{
        "pts" => sequence * 3_000,
        "observed_at" => DateTime.to_iso8601(DateTime.utc_now())
      },
      "objects" => objects
    })
  end

  defp object(label, score) do
    %{"label" => label, "score" => score, "bbox" => [0.1, 0.1, 0.2, 0.4]}
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

  # A plugin that reads its stdin and appends every control line to a file:
  # the only way to see what the port actually wrote.
  defp stdin_recorder do
    path =
      Path.join(System.tmp_dir!(), "cairn_group_ctl_#{System.unique_integer([:positive])}.ndjson")

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
      length(lines) >= count ->
        lines

      attempts == 0 ->
        flunk("plugin received #{length(lines)} control lines, wanted #{count}")

      true ->
        # the poll interval — without it the attempts burn out in microseconds
        Process.sleep(25)
        await_control(path, count, attempts - 1)
    end
  end

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
    start_group_port([a, b], command: command, tracker: self())

    a_id = a.id
    b_id = b.id

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^a_id}, policy_a, %Observation{pts: 1} = obs_a}},
                   5_000

    assert policy_a == %{
             pre: 5,
             post: 10,
             max: 300,
             max_unseen_ms: 3_000,
             max_live_tracks: 128,
             stationary_after_ms: 10_000,
             bbd: false,
             track: nil,
             record: nil
           }

    assert [%{label: "person", score: 0.9}] = obs_a.objects

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^b_id}, policy_b, %Observation{pts: 2}}},
                   5_000

    assert policy_b == %{
             pre: 5,
             post: 42,
             max: 300,
             max_unseen_ms: 3_000,
             max_live_tracks: 128,
             stationary_after_ms: 10_000,
             bbd: false,
             track: nil,
             record: nil
           }
  end

  # One `Cairn.ObservationClock` per member, not one per group: the members are
  # separate streams with separate pts, and a group serves whichever of them is
  # still delivering.
  test "each member's observations carry their own at_ms, on the host's clock" do
    a = camera("gp_clock_a_#{System.unique_integer([:positive])}")
    b = camera("gp_clock_b_#{System.unique_integer([:positive])}")

    command =
      printf([
        det_line(a.id, 1, 0.9),
        det_line(b.id, 900_000, 0.9),
        det_line(a.id, 2, 0.9)
      ]) <> "; exec sleep 30"

    start_group_port([a, b], command: command, tracker: self())

    a_id = a.id
    b_id = b.id

    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, _p, first}}, 5_000
    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^b_id}, _p, other}}, 5_000
    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, _p, second}}, 5_000

    now = System.monotonic_time(:millisecond)

    # b's pts is ten seconds ahead of a's and buys it nothing: each member is
    # anchored on its own, and no member's clock may run ahead of the host's
    assert other.at_ms <= now
    assert first.at_ms <= now
    assert second.at_ms > first.at_ms
  end

  test "each camera's own min_score applies through its camera tracker" do
    a = camera("gp_low_#{System.unique_integer([:positive])}")
    b = camera("gp_high_#{System.unique_integer([:positive])}", min_score: %{"default" => 0.95})

    for cam <- [a, b] do
      start_supervised!(
        {CameraTracker,
         camera_id: cam.id,
         start_extractor: fn _c, _e -> {:ok, spawn(fn -> Process.sleep(:infinity) end)} end},
        id: {:tracker, cam.id}
      )
    end

    Event.subscribe()

    # 0.7 clears cam a's 0.5 floor and is filtered out for cam b's 0.95
    command = printf([det_line(b.id, 1, 0.7), det_line(a.id, 2, 0.7)]) <> "; exec sleep 30"
    start_group_port([a, b], command: command)

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

    pid = start_group_port([a], command: command, tracker: self())

    a_id = a.id

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^a_id}, _policy, %Observation{pts: 3}}},
                   5_000

    assert %PluginGroupPort{} = :sys.get_state(pid)
  end

  test "over-long lines are skipped and the next line still routes" do
    a = camera("gp_long_#{System.unique_integer([:positive])}")
    long = String.duplicate("x", 70_000)

    command = printf([long, det_line(a.id, 7, 0.9)]) <> "; exec sleep 30"
    pid = start_group_port([a], command: command, tracker: self())

    a_id = a.id

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^a_id}, _policy, %Observation{pts: 7}}},
                   5_000

    assert %PluginGroupPort{} = :sys.get_state(pid)
  end

  test "a line at exactly the 65_536-byte limit still routes" do
    a = camera("gp_65536_#{System.unique_integer([:positive])}")
    line = padded_line(a.id, 11, 65_536)
    assert byte_size(line) == 65_536

    # {:line, 65_536} delivers up to 65_536 bytes of line data as {:eol, _}
    # and only splits above that, so the limit itself is accepted
    command = printf([line]) <> "; exec sleep 30"
    pid = start_group_port([a], command: command, tracker: self())

    a_id = a.id

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^a_id}, _windows, %Observation{pts: 11} = obs}},
                   5_000

    assert [%{label: "person"}] = obs.objects
    assert %PluginGroupPort{} = :sys.get_state(pid)
  end

  test "a line one byte over the limit is dropped and the next line still routes" do
    a = camera("gp_65537_#{System.unique_integer([:positive])}")
    over = padded_line(a.id, 12, 65_537)
    assert byte_size(over) == 65_537

    # delivered as {:noeol, 65_536} + {:eol, 1}: the one-byte remainder is what
    # has to clear skipping_long_line before line 13 arrives
    command = printf([over, det_line(a.id, 13, 0.9)]) <> "; exec sleep 30"
    pid = start_group_port([a], command: command, tracker: self())

    a_id = a.id

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^a_id}, _windows, %Observation{pts: 13}}},
                   5_000

    assert %PluginGroupPort{} = :sys.get_state(pid)
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
    pid = start_group_port([a], command: command, tracker: self())

    a_id = a.id

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^a_id}, _policy, %Observation{pts: 1} = obs}},
                   5_000

    assert [%{label: "cat", score: 0.8, bbox: [0.1, 0.1, 0.2, 0.2]}] = obs.objects

    # the non-numeric pts line is dropped whole, so the next cast is the last line
    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^a_id}, _policy, %Observation{pts: 3} = good}},
                   5_000

    assert [%{label: "person", score: 0.9, bbox: [0, 0, 1, 1]}] = good.objects
    assert %PluginGroupPort{} = :sys.get_state(pid)
  end

  test "a malformed bbox never reaches `Cairn.Tracker`" do
    a = camera("gp_bbox_#{System.unique_integer([:positive])}")

    tracker =
      start_supervised!(
        {CameraTracker,
         camera_id: a.id,
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

    pid = start_group_port([a], command: command)

    a_id = a.id
    assert_receive {:event_started, %Event{camera_id: ^a_id}}, 5_000

    # only reachable if the batch *after* the poisoned one was tracked: pre-fix
    # :event_started fired on line 1 and the crash landed on line 2
    assert_receive {:event_updated, %Event{camera_id: ^a_id}}, 5_000
    # a round-trip through each: the camera tracker survived the poisoned batch and
    # the port survived forwarding it
    assert %{} = :sys.get_state(tracker)
    assert %PluginGroupPort{} = :sys.get_state(pid)
  end

  test "refresh swaps the routes without restarting the plugin process" do
    a = camera("gp_refresh_#{System.unique_integer([:positive])}")

    # the second line has to arrive after the refresh cast is handled, so the
    # fake's window is wide and the cast is flushed synchronously below
    command =
      printf([det_line(a.id, 1, 0.9)]) <>
        "; sleep 5; " <> printf([det_line(a.id, 2, 0.9)]) <> "; exec sleep 30"

    pid = start_group_port([a], command: command, tracker: self())
    a_id = a.id

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^a_id}, policy, %Observation{pts: 1}}},
                   5_000

    assert policy.post == 10
    os_pid = :sys.get_state(pid).os_pid

    # the group is unchanged; only a camera field the argv never carried moved
    widened = %Camera{a | post_window_seconds: 42}
    :ok = PluginGroupPort.refresh(pid, group([widened]), config([widened]))
    # flush the cast: it must be handled before the fake emits line 2
    :sys.get_state(pid)

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^a_id, post_window_seconds: 42}, %{post: 42},
                     %Observation{pts: 2}}},
                   10_000

    assert :sys.get_state(pid).os_pid == os_pid
  end

  test "refresh prunes a dropped member's clock and bookkeeping" do
    a = camera("gp_prune_a_#{System.unique_integer([:positive])}")
    b = camera("gp_prune_b_#{System.unique_integer([:positive])}")

    command = printf([det_line(a.id, 1, 0.9), det_line(b.id, 2, 0.9)]) <> "; exec sleep 30"
    pid = start_group_port([a, b], command: command, tracker: self())

    a_id = a.id
    b_id = b.id
    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, _, _}}, 5_000
    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^b_id}, _, _}}, 5_000
    assert Map.has_key?(:sys.get_state(pid).clocks, b_id)

    # ids churning across refreshes must not accumulate entries for the life
    # of the port — the maps follow the routes
    :ok = PluginGroupPort.refresh(pid, group([a]), config([a]))

    state = :sys.get_state(pid)
    assert Map.has_key?(state.clocks, a_id)

    for map <- [state.clocks, state.last_sequences, state.epochs, state.last_statuses] do
      refute Map.has_key?(map, b_id)
    end
  end

  test "unroutable lines are counted but only logged periodically" do
    a = camera("gp_flood_#{System.unique_integer([:positive])}")
    strangers = for pts <- 1..5, do: det_line("stranger", pts, 0.9)
    command = printf(strangers ++ [det_line(a.id, 99, 0.9)]) <> "; exec sleep 30"

    log =
      capture_log(fn ->
        start_group_port([a], command: command, tracker: self())
        # ordered after all five drops: the port handles lines in order
        assert_receive {:"$gen_cast", {:detections, _cam, _policy, %Observation{pts: 99}}}, 5_000
      end)

    assert length(Regex.scan(~r/dropped lines\/dets/, log)) == 1
    assert log =~ ~s|unknown_camera ×1 (1 total); latest unknown_camera: "stranger"|
  end

  test "every member's epoch is announced on stdin, and only that member's" do
    a = camera("gp_ctl_a_#{System.unique_integer([:positive])}")
    b = camera("gp_ctl_b_#{System.unique_integer([:positive])}")

    a_epoch = StreamEpochs.new_epoch(a.id, :started)
    b_epoch = StreamEpochs.new_epoch(b.id, :started)
    {path, command} = stdin_recorder()

    pid = start_group_port([a, b], command: command, tracker: self())

    started = await_control(path, 2)
    assert Enum.all?(started, &(&1["type"] == "stream.started"))

    assert Map.new(started, &{&1["camera_id"], &1["stream_epoch"]}) == %{
             a.id => a_epoch,
             b.id => b_epoch
           }

    # one member bouncing touches that member only — and never the process
    os_pid = :sys.get_state(pid).os_pid
    a_next = StreamEpochs.new_epoch(a.id, :stall_bounce)

    assert [_, _, ended, restarted] = await_control(path, 4)

    assert %{"type" => "stream.ended", "reason" => "stall_bounce", "stream_epoch" => ^a_epoch} =
             ended

    assert ended["camera_id"] == a.id
    assert %{"type" => "stream.started", "stream_epoch" => ^a_next} = restarted
    assert restarted["camera_id"] == a.id

    # a camera that is not a member of this group is not its business.
    # new_epoch/3 returns only once the broadcast has been delivered, so the
    # :sys.get_state barrier proves the port *handled* it; the sentinel below
    # then proves it wrote nothing for it.
    StreamEpochs.new_epoch("gp_ctl_stranger_#{System.unique_integer([:positive])}", :started)
    _ = :sys.get_state(pid)

    b_next = StreamEpochs.new_epoch(b.id, :stall_bounce)
    assert [_, _, _, _, b_ended, b_restarted] = await_control(path, 6)
    assert %{"type" => "stream.ended", "stream_epoch" => ^b_epoch} = b_ended
    assert b_ended["camera_id"] == b.id
    assert %{"type" => "stream.started", "stream_epoch" => ^b_next} = b_restarted

    assert %PluginGroupPort{os_pid: ^os_pid} = :sys.get_state(pid)
  end

  test "v1 lines route per member, with per-camera sequence and epoch state" do
    a = camera("gp_v1_a_#{System.unique_integer([:positive])}")
    b = camera("gp_v1_b_#{System.unique_integer([:positive])}")

    a_epoch = StreamEpochs.new_epoch(a.id, :started)
    b_epoch = StreamEpochs.new_epoch(b.id, :started)
    test_pid = self()

    handler = "gp_seq_gap_#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:cairn, :plugin, :sequence_gap],
      fn _event, measurements, metadata, _ -> send(test_pid, {:gap, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    command =
      printf([
        v1_line(a.id, a_epoch, 5, [object("person", 0.9)]),
        # b's first line is sequence 1: per-camera counters, so a's 5 is not
        # a baseline for it and this must not read as a gap
        v1_line(b.id, b_epoch, 1, [object("person", 0.9)]),
        # a stale epoch for a is dropped and leaves b's state alone
        v1_line(a.id, "01OTHEREPOCH0000000000000", 6, [object("person", 0.9)]),
        v1_line(b.id, b_epoch, 2, [object("person", 0.9)]),
        v1_line(a.id, a_epoch, 9, [object("person", 0.9)])
      ]) <> "; exec sleep 30"

    pid = start_group_port([a, b], command: command, tracker: self())

    a_id = a.id
    b_id = b.id

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^a_id}, _w, %Observation{sequence: 5}}},
                   5_000

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^b_id}, _w, %Observation{sequence: 1}}},
                   5_000

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^b_id}, _w, %Observation{sequence: 2}}},
                   5_000

    # the stale line never reaches the camera tracker; the next good one does
    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^a_id}, _w, %Observation{sequence: 9}}},
                   5_000

    # sequences 6..8 (the stale line's number included) are a gap of 3 for a…
    assert_receive {:gap, %{count: 3}, %{camera_id: ^a_id}}, 5_000
    # …and b, whose counter ran 1 -> 2 independently, contributed none
    refute_received {:gap, _measurements, %{camera_id: ^b_id}}
    assert :sys.get_state(pid).drops == %{stale_epoch: 1, sequence_gap: 3}
  end

  test "an epoch change re-baselines that member's sequence, and only that member's" do
    a = camera("gp_seqep_a_#{System.unique_integer([:positive])}")
    b = camera("gp_seqep_b_#{System.unique_integer([:positive])}")

    a_first = StreamEpochs.new_epoch(a.id, :started)
    b_epoch = StreamEpochs.new_epoch(b.id, :started)

    # a plugin that emits nothing: every line below is fed by hand, so the
    # epoch change lands at an exact point in the stream rather than wherever
    # the shell's output happens to be
    pid = start_group_port([a, b], command: "exec sleep 30", tracker: self())
    port = :sys.get_state(pid).port
    feed = fn line -> send(pid, {port, {:data, {:eol, line}}}) end

    a_id = a.id
    b_id = b.id

    feed.(v1_line(a.id, a_first, 0, [object("person", 0.9)]))
    feed.(v1_line(b.id, b_epoch, 0, [object("person", 0.9)]))

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^a_id}, _w, %Observation{sequence: 0}}},
                   5_000

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^b_id}, _w, %Observation{sequence: 0}}},
                   5_000

    a_second = StreamEpochs.new_epoch(a.id, :stall_bounce)

    # a's last line under the retired epoch, refused as stale: it consumed
    # sequence 1 and no accepted line ever will, so counting it again as a
    # lost frame would describe something that did not happen
    feed.(v1_line(a.id, a_first, 1, [object("person", 0.9)]))
    feed.(v1_line(a.id, a_second, 0, [object("person", 0.9)]))
    # b never bounced: its own timeline is untouched and still gap-checked
    feed.(v1_line(b.id, b_epoch, 1, [object("person", 0.9)]))

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^a_id}, _w, %Observation{sequence: 0}}},
                   5_000

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^b_id}, _w, %Observation{sequence: 1}}},
                   5_000

    assert :sys.get_state(pid).drops == %{stale_epoch: 1}

    # and a forward jump *within* an epoch is still a gap for the member that
    # made it
    feed.(v1_line(b.id, b_epoch, 4, [object("person", 0.9)]))

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^b_id}, _w, %Observation{sequence: 4}}},
                   5_000

    assert :sys.get_state(pid).drops == %{stale_epoch: 1, sequence_gap: 2}
  end

  test "a v1 hello and status route through the group" do
    a = camera("gp_v1_hs_a_#{System.unique_integer([:positive])}")
    b = camera("gp_v1_hs_b_#{System.unique_integer([:positive])}")

    message = fn fields ->
      Jason.encode!(Map.merge(%{"spec" => "cairn.plugin", "version" => 1}, fields))
    end

    command =
      printf([
        message.(%{
          "type" => "plugin.hello",
          "hello" => %{"name" => "fake", "version" => "2.0", "supported_versions" => [1]}
        }),
        message.(%{"type" => "plugin.status", "status" => %{"state" => "ready"}}),
        message.(%{
          "type" => "plugin.status",
          "camera_id" => a.id,
          "status" => %{"state" => "degraded"}
        }),
        # unchanged and inside the min interval: not a second broadcast
        message.(%{
          "type" => "plugin.status",
          "camera_id" => a.id,
          "status" => %{"state" => "degraded"}
        })
      ]) <> "; exec sleep 30"

    Cairn.CameraStatus.subscribe()

    on_exit(fn ->
      Cairn.CameraStatus.prune(Map.keys(Cairn.CameraStatus.all()) -- [a.id, b.id])
    end)

    pid = start_group_port([a, b], command: command, tracker: self())

    a_id = a.id
    b_id = b.id
    assert_receive {:camera_status, ^a_id, %{plugin_status: %{"state" => "ready"}}}, 5_000
    assert_receive {:camera_status, ^b_id, %{plugin_status: %{"state" => "ready"}}}, 5_000
    assert_receive {:camera_status, ^a_id, %{plugin_status: %{"state" => "degraded"}}}, 5_000

    # the envelope's camera_id routed the status and stops there: what is
    # stored is keyed by camera already
    assert Cairn.CameraStatus.get(a_id).plugin_status == %{"state" => "degraded"}
    assert Cairn.CameraStatus.get(b_id).plugin_status == %{"state" => "ready"}

    # the repeat is gated: b never hears about a, and a is not told twice
    refute_receive {:camera_status, ^b_id, %{plugin_status: %{"state" => "degraded"}}}, 200
    refute_received {:camera_status, ^a_id, %{plugin_status: %{"state" => "degraded"}}}

    state = :sys.get_state(pid)
    assert %{"name" => "fake"} = state.plugin
    assert %{status_rate_limited: 1} = state.drops
  end

  test "an epoch older than the one already announced is ignored per member" do
    a = camera("gp_order_a_#{System.unique_integer([:positive])}")
    b = camera("gp_order_b_#{System.unique_integer([:positive])}")

    StreamEpochs.new_epoch(a.id, :started)
    b_epoch = StreamEpochs.new_epoch(b.id, :started)
    {path, command} = stdin_recorder()

    pid = start_group_port([a, b], command: command, tracker: self())
    assert [_, _] = await_control(path, 2)

    a_second = StreamEpochs.new_epoch(a.id, :source_lost)
    assert [_, _, _, _] = await_control(path, 4)

    # a late broadcast for an earlier mint. Applying it would leave the plugin
    # stamping a's lines with a dead epoch while `current_epoch?/2` compares
    # against ETS — every one of a's observations dropped until the next
    # respawn — and it must not touch b either.
    send(pid, {:stream_epoch, a.id, Cairn.ULID.generate(1), :source_lost})
    state = :sys.get_state(pid)
    assert state.epochs[a.id] == {a_second, :live}
    assert state.epochs[b.id] == {b_epoch, :live}

    # sentinel: the next real mint for a ends `a_second`, so nothing was
    # written for the stale one in between
    a_third = StreamEpochs.new_epoch(a.id, :stall_bounce)
    assert [_, _, _, _, ended, restarted] = await_control(path, 6)
    assert %{"type" => "stream.ended", "stream_epoch" => ^a_second} = ended
    assert %{"type" => "stream.started", "stream_epoch" => ^a_third} = restarted
  end

  test "status routes to the named member, or to all of them" do
    a = camera("gp_st_a_#{System.unique_integer([:positive])}")
    b = camera("gp_st_b_#{System.unique_integer([:positive])}")

    status = fn fields ->
      Jason.encode!(
        Map.merge(
          %{"spec" => "cairn.plugin", "version" => 1, "type" => "plugin.status"},
          fields
        )
      )
    end

    command =
      printf([
        status.(%{"status" => %{"state" => "ready"}}),
        status.(%{"camera_id" => a.id, "status" => %{"state" => "degraded"}})
      ]) <> "; exec sleep 30"

    Cairn.CameraStatus.subscribe()

    on_exit(fn ->
      Cairn.CameraStatus.prune(Map.keys(Cairn.CameraStatus.all()) -- [a.id, b.id])
    end)

    start_group_port([a, b], command: command, tracker: self())

    a_id = a.id
    b_id = b.id
    assert_receive {:camera_status, ^a_id, %{plugin_status: %{"state" => "ready"}}}, 5_000
    assert_receive {:camera_status, ^b_id, %{plugin_status: %{"state" => "ready"}}}, 5_000

    # the second line names one member: only that member changes
    assert_receive {:camera_status, ^a_id, %{plugin_status: %{"state" => "degraded"}}}, 5_000
    assert Cairn.CameraStatus.get(b_id).plugin_status["state"] == "ready"
  end

  # The capability buys a plugin nothing — the host tracks every object itself —
  # so declaring it is warned about once for the whole group and changes nothing
  # about any member's observations, whose `track_id`s still arrive and are
  # still ignored. Both attribution paths (v0 and v1) are driven here.
  test "an object_tracking declaration is warned about and changes no observation" do
    for {capabilities, declared} <- [{%{"object_tracking" => true}, true}, {%{}, false}] do
      a = camera("gp_cap_a_#{System.unique_integer([:positive])}")
      b = camera("gp_cap_b_#{System.unique_integer([:positive])}")

      a_epoch = StreamEpochs.new_epoch(a.id, :started)
      b_epoch = StreamEpochs.new_epoch(b.id, :started)

      hello =
        Jason.encode!(%{
          "spec" => "cairn.plugin",
          "version" => 1,
          "type" => "plugin.hello",
          "hello" => %{
            "name" => "fake",
            "supported_versions" => [1],
            "capabilities" => capabilities
          }
        })

      tracked = [Map.put(object("person", 0.9), "track_id", "t1")]

      command =
        printf([
          hello,
          v1_line(a.id, a_epoch, 1, tracked),
          v1_line(b.id, b_epoch, 1, tracked),
          # v0 lines are attributed by a separate clause that stamps the flag
          # of its own; neither port had it under test
          det_line(a.id, 7, 0.9)
        ]) <> "; exec sleep 30"

      a_id = a.id
      b_id = b.id

      log =
        capture_log(fn ->
          start_group_port([a, b],
            command: command,
            tracker: self(),
            group_name: "detect_cap_#{declared}",
            id: {:cap, declared}
          )

          assert_receive {:"$gen_cast",
                          {:detections, %Camera{id: ^a_id}, _policy,
                           %Observation{protocol: :v1} = obs_a}},
                         5_000

          # the ids are on the wire and reach every member's observation;
          # nothing acts on them
          assert [%{track_id: "t1"}] = obs_a.objects

          assert_receive {:"$gen_cast",
                          {:detections, %Camera{id: ^b_id}, _policy,
                           %Observation{protocol: :v1} = obs_b}},
                         5_000

          assert [%{track_id: "t1"}] = obs_b.objects

          assert_receive {:"$gen_cast",
                          {:detections, %Camera{id: ^a_id}, _policy, %Observation{protocol: :v0}}},
                         5_000
        end)

      assert log =~ "declares object_tracking" == declared

      if declared do
        assert log =~ "host-side tracking is used and plugin track ids are ignored"
      end
    end
  end

  test "plugin exit triggers backoff respawn" do
    a = camera("gp_exit_#{System.unique_integer([:positive])}")

    # exits after one line; the respawned process emits it again
    command = printf([det_line(a.id, 1, 0.9)])

    start_group_port([a],
      command: command,
      tracker: self(),
      backoff_min_ms: 50,
      backoff_max_ms: 100
    )

    a_id = a.id

    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, _w, %Observation{pts: 1}}},
                   5_000

    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^a_id}, _w, %Observation{pts: 1}}},
                   5_000
  end
end
