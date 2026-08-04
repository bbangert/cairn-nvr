defmodule Cairn.PluginPortTest do
  # async: false — these tests share the "events" PubSub topic and capture_log.
  # DataCase because they start real camera trackers, whose checkpoint restore
  # consults the event index.
  use Cairn.DataCase, async: false

  import ExUnit.CaptureLog

  alias Cairn.{CameraTracker, Event, Observation, PluginPort, StreamEpochs, Track, ULID}
  alias Cairn.Config.Camera

  @mock Path.absname("priv/plugins/mock/mock_plugin.exs")
  @timeline Path.absname("test/support/fixtures/timelines/person_walkthrough.json")
  # Real detections, a stretch of seeded `"tracked"` re-reports of the same
  # box, then real detections again — what `plugins/cairn-detect`'s motion gate
  # emits for a still scene.
  @gated_timeline Path.absname("test/support/fixtures/timelines/gated_stretch.json")
  # Confident detections, a stretch of the same object emitted *below* the
  # camera's floor at its real score, then confident again — an occlusion as a
  # detector reports one, plus a below-floor box that belongs to nothing.
  @subfloor_timeline Path.absname("test/support/fixtures/timelines/low_conf_occlusion.json")

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

  defp v1_line(camera_id, epoch, sequence, objects, frame \\ %{}) do
    Jason.encode!(%{
      "spec" => "cairn.plugin",
      "version" => 1,
      "type" => "frame.objects",
      "camera_id" => camera_id,
      "stream_epoch" => epoch,
      "sequence" => sequence,
      # the port clamps an `observed_at` far from host time, so a line that is
      # not about clock skew has to carry a live one
      "frame" =>
        Map.merge(
          %{"pts" => sequence * 3_000, "observed_at" => DateTime.to_iso8601(DateTime.utc_now())},
          frame
        ),
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

  test "build_argv appends contract arguments" do
    argv = PluginPort.build_argv(camera("c"), 17_002)

    assert ["elixir", @mock, "--camera-id", "c", "--udp-port", "17002", "--min-score-json", json] =
             argv

    assert Jason.decode!(json) == %{"default" => 0.5}
  end

  test "mock plugin timeline drives the camera tracker through a full Port" do
    id = "plug_#{System.unique_integer([:positive])}"
    test_pid = self()

    # the mock speaks v1: it stamps its lines with the epoch the port hands it
    # on stdin, and the port drops anything from another epoch
    StreamEpochs.new_epoch(id, :started)

    start_supervised!(
      {CameraTracker,
       camera_id: id,
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
      {PluginPort, camera: camera(id), config: config(), index: 0, command: command}
    )

    assert_receive {:event_started, %Event{camera_id: ^id} = event}, 5_000
    assert [%{label: "person"}] = event.labels

    # third batch has person (0.93, passes) + cat (0.4, filtered by 0.5 default)
    assert_receive {:event_updated, %Event{camera_id: ^id}}, 5_000
    assert_receive {:event_updated, %Event{camera_id: ^id} = updated}, 5_000
    assert Map.keys(updated.max_scores) == ["person"]
  end

  # The parse side is already covered — `Cairn.PluginProtocolTest`, "objects
  # carry track_id and observation_kind" — so what is left to prove is the
  # tracking consequence: a plugin that stops inferring and re-reports what it
  # last saw must not cost the object its identity or its stillness. Nothing
  # host-side changed for this; the gate rides semantics that were already here.
  test "a gated stretch of seeded lines keeps the track it re-reports" do
    id = "plug_gated_#{System.unique_integer([:positive])}"
    StreamEpochs.new_epoch(id, :started)

    # Both bounds are scaled down to the timeline, and the stretch is sized
    # against the bound the track actually expires on. The object parks 1.2 s
    # in, so it is `stationary` before the seeds start at 1.8 s — and a
    # stationary track's unseen bound is `@stationary_unseen_factor` (5) ×
    # `max_unseen_ms`, i.e. 2 000 ms here, not 400. The seeds run 1.8–5.7 s and
    # the next real detection lands at 6.0 s, so the stretch the seeds carry the
    # track across is 4 500 ms of unseen time: past the 2 000 ms bound with
    # margin to spare, while the 300 ms seed cadence stays inside it. Replace
    # the seeded lines with the empty-`objects` liveness lines an unmemoried
    # gate emits and the track expires mid-stretch, taking its identity with it.
    # The shipped defaults — `stationary_after_ms` 10 s and `max_unseen_ms` 3 s,
    # so 15 s of stationary grace — would have put this test past 25 seconds.
    camera = %Camera{camera(id) | stationary_after_ms: 1_000, max_unseen_ms: 400}

    tracker =
      start_supervised!(
        {CameraTracker,
         camera_id: id,
         start_extractor: fn _camera, _event ->
           {:ok, spawn(fn -> Process.sleep(:infinity) end)}
         end}
      )

    Event.subscribe()

    command =
      "elixir #{@mock} --camera-id #{id} --udp-port 19100 " <>
        "--min-score-json '{}' --timeline #{@gated_timeline} --hold"

    start_supervised!({PluginPort, camera: camera, config: config(), index: 0, command: command})

    # the identity minted by the first real detection, before any seed
    assert_receive {:event_started, %Event{camera_id: ^id} = event}, 5_000
    assert [%{label: "person", object_id: object_id}] = event.labels

    # Mid-stretch, and receivable only if the seeded batches reached the
    # tracker: `stale_predicted` is recomputed per batch from
    # `last_detected_ms`, which a seed does not move, so it flips true once a
    # batch arrives more than `max_unseen_ms` (400 ms) after the last real
    # detection at 1.5 s. No batch, no flip — every detection in this timeline
    # is broadcast with it false.
    assert_receive {:track_updated,
                    %Track{
                      object_id: ^object_id,
                      stale_predicted: true,
                      stationary: true
                    }},
                   10_000

    # The timeline's last line is a real detection at 0.99, so this broadcast
    # is the far side of the seeded stretch — and it carries the identity the
    # first detection minted, not a new one.
    assert_receive {:track_updated,
                    %Track{
                      object_id: ^object_id,
                      best_score: 0.99,
                      stationary: true,
                      stale_predicted: false
                    }},
                   10_000

    # one track, the same one, still parked: the seeds sustained it without
    # minting an identity and without touching the stillness only detections
    # can earn or lose
    assert [%Track{object_id: ^object_id, stationary: true}] =
             Cairn.Tracker.live_tracks(:sys.get_state(tracker).tracker)
  end

  # The case the two-stage association exists for, through a real Port: an
  # object detected confidently, then emitted for nine batches — two and a half
  # seconds — at a score below the camera's `min_score`, real detections the
  # detector is unsure of rather than
  # the plugin's own predictions, and then confident again. Only stage two can
  # keep that one identity, and only because `Cairn.CameraTracker` puts the
  # camera's effective floor in the tracking context; without the floor every
  # box is stage one and the below-floor half would be minting tracks instead.
  #
  # The control the stage rides on is in the same timeline, in every batch: a
  # second below-floor box far from the first, which no live track overlaps and
  # which must therefore mint nothing, ever.
  test "a sub-floor stretch carries the track it lands on and mints nothing" do
    id = "plug_subfloor_#{System.unique_integer([:positive])}"
    StreamEpochs.new_epoch(id, :started)

    # `max_unseen_ms` is scaled down to the timeline as the gated-stretch test
    # scales it. The last confident detection lands at 0.3 s and the next at
    # 3.3 s, so the object goes 3 s with nothing a stage-one pass would take:
    # seven times the 400 ms bound. Stop matching the below-floor boxes and the
    # track is gone by 0.9 s — a below-floor box that takes no track is dropped
    # outright and marks nothing seen — so the 0.95 detection on the far side
    # arrives to an empty tracker and mints a second identity.
    #
    # `stationary_after_ms` is scaled *up* instead, past the whole timeline.
    # The box never moves, and a stationary track is not evidence whatever its
    # score, which would give the "a sub-floor box never earns video" assertion
    # below a second reason to hold and stop it proving the first. It also
    # keeps the unseen bound a plain `max_unseen_ms` rather than the stationary
    # multiple of it.
    camera = %Camera{camera(id) | stationary_after_ms: 30_000, max_unseen_ms: 400}

    tracker =
      start_supervised!(
        {CameraTracker,
         camera_id: id,
         start_extractor: fn _camera, _event ->
           {:ok, spawn(fn -> Process.sleep(:infinity) end)}
         end}
      )

    Event.subscribe()

    command =
      "elixir #{@mock} --camera-id #{id} --udp-port 19100 " <>
        "--min-score-json '{}' --timeline #{@subfloor_timeline} --hold"

    start_supervised!({PluginPort, camera: camera, config: config(), index: 0, command: command})

    # the identity the first confident detection minted, and the only one this
    # timeline may mint — which the `refute_received` below is what proves
    assert_receive {:track_started, %Track{object_id: object_id, label: "person"}}, 5_000

    assert_receive {:event_started, %Event{camera_id: ^id} = event}, 5_000
    assert [%{label: "person", object_id: ^object_id}] = event.labels

    # Mid-stretch, and receivable only if a below-floor box took the track:
    # `score` is the latest observation's, so 0.3 says the batch behind this
    # summary was matched by a sub-floor detection, and matched as a real
    # detection — `stale_predicted` stays false, where the plugin's own
    # re-reports would have flipped it. What the match may not do is raise
    # `best_score`, which is still what the confident detections left.
    assert_receive {:track_updated,
                    %Track{
                      object_id: ^object_id,
                      score: 0.3,
                      best_score: 0.9,
                      stale_predicted: false,
                      stationary: false
                    }},
                   10_000

    # The far side of the stretch, carrying the identity the first detection
    # minted rather than a new one: the whole point of the stage.
    assert_receive {:track_updated, %Track{object_id: ^object_id, score: 0.95, best_score: 0.95}},
                   10_000

    # Nothing else was ever minted — not the box that belongs to no track, and
    # not a replacement for one that expired mid-stretch. Mailbox assertions,
    # which is sound here because every summary this camera publishes comes
    # from the one process in batch order: anything the stretch broadcast is
    # already behind us.
    refute_received {:track_started, _}
    refute_received {:track_ended, _}

    # And no sub-floor batch was ever evidence. The only two updates the event
    # took are the confident batch at 0.3 s and the one on the far side; a
    # stretch batch that earned video would have published a third between
    # them, carrying the 0.9 the confident half had already reached, and the
    # second assertion here would have matched it.
    assert_receive {:event_updated, %Event{camera_id: ^id, max_score: 0.9}}, 5_000
    assert_receive {:event_updated, %Event{camera_id: ^id, max_score: 0.95}}, 5_000
    refute_received {:event_updated, _}

    assert [%Track{object_id: ^object_id, score: 0.95}] =
             Cairn.Tracker.live_tracks(:sys.get_state(tracker).tracker)
  end

  test "malformed lines are dropped without crashing" do
    id = "plug_#{System.unique_integer([:positive])}"

    start_supervised!(
      {CameraTracker,
       camera_id: id,
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
        {PluginPort, camera: camera(id), config: config(), index: 0, command: command}
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
         camera: camera(id), config: config(), index: 0, command: command, tracker: self()}
      )

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^id}, policy, %Observation{pts: 1} = obs}},
                   5_000

    # resolved once at spawn and carried on every cast — the per-frame path
    # must never reach the config server, and the camera tracker reads
    # `max_unseen_ms` from here to expire tracks
    assert policy == Cairn.Config.policy(config(), camera(id))
    assert policy == :sys.get_state(pid).policy
    assert is_number(policy.max_unseen_ms)

    assert [%{label: "cat", score: 0.8, bbox: [0.1, 0.1, 0.2, 0.2]}] = obs.objects

    # the non-numeric pts line is dropped whole, so the next cast is the last line
    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^id}, _policy, %Observation{pts: 3} = good}},
                   5_000

    assert [%{label: "person", score: 0.9, bbox: [0, 0, 1, 1]}] = good.objects
    assert %PluginPort{} = :sys.get_state(pid)
  end

  test "a malformed bbox never reaches `Cairn.Tracker`" do
    id = "plug_#{System.unique_integer([:positive])}"

    tracker =
      start_supervised!(
        {CameraTracker,
         camera_id: id,
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
        {PluginPort, camera: camera(id), config: config(), index: 0, command: command}
      )

    assert_receive {:event_started, %Event{camera_id: ^id} = event}, 5_000
    assert [%{label: "person"}] = event.labels

    # only reachable if the batch *after* the poisoned one was tracked: pre-fix
    # :event_started fired on line 1 and the crash landed on line 2
    assert_receive {:event_updated, %Event{camera_id: ^id}}, 5_000
    # a round-trip through each: the camera tracker survived the poisoned batch and
    # the port survived forwarding it
    assert %{} = :sys.get_state(tracker)
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
         camera: camera(id), config: config(), index: 0, command: command, tracker: self()}
      )

    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^id}, _policy, %Observation{pts: 7}}},
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
           camera: camera(id), config: config(), index: 0, command: command, tracker: self()}
        )

        # ordered after the flood: the port handles lines in order
        assert_receive {:"$gen_cast",
                        {:detections, %Camera{id: ^id}, _policy, %Observation{pts: 2}}},
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
       camera: camera(id), config: config(), index: 0, command: command, tracker: self()}
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

    # …and nothing else. A sentinel rather than a sleep: the next mint's
    # `stream.started` must be the *fifth* line, so a spurious start written
    # for the stopped epoch shows up as a mismatch here instead of as a
    # timing-dependent count.
    third = StreamEpochs.new_epoch(id, :started)
    assert [_, _, _, _, sentinel] = await_control(path, 5)
    assert %{"type" => "stream.started", "stream_epoch" => ^third} = sentinel
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
        camera: camera(id), config: config(), index: 0, command: "exec sleep 60", tracker: self()
      })

    # far more than the pipe buffer plus the port's busy watermark, so the
    # writes must go through the :nosuspend path that drops instead of blocking
    capture_log(fn -> for _ <- 1..1_000, do: StreamEpochs.new_epoch(id, :stall_bounce) end)
    assert {:ok, last} = StreamEpochs.current(id)

    state = :sys.get_state(pid)
    assert %PluginPort{} = state
    # the plugin never read its stdin, so the writes were dropped, not queued.
    # Matched, not indexed: `state.drops[:control_stdin_busy] > 0` is `nil > 0`
    # — true — when nothing was counted at all.
    assert %{control_stdin_busy: busy} = state.drops
    assert busy > 0

    # an epoch whose write was dropped is not recorded as announced: the port
    # still believes the last epoch it managed to send, so the next epoch
    # event (or the next spawn's pull from ETS) announces the current one
    # again instead of leaving this camera silently on a dead epoch
    # (a pair whose `stream.ended` went through and whose `stream.started` did
    # not is recorded as `:ended`, so no second `ended` precedes the retry)
    assert {recorded, liveness} = state.epoch
    assert liveness in [:live, :ended]
    refute recorded == last
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
         camera: camera(id), config: config(), index: 0, command: command, tracker: self()}
      )

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^id}, _policy, %Observation{sequence: 1}}},
                   5_000

    # the stale line never reaches the camera tracker; the next good one does
    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^id}, _policy, %Observation{sequence: 5}}},
                   5_000

    # sequences 2..4 (the stale line's number included) are a gap of 3
    assert_receive {:gap, %{count: 3}, %{camera_id: ^id}}, 5_000
    assert :sys.get_state(pid).drops == %{stale_epoch: 1, sequence_gap: 3}
  end

  test "an epoch change re-baselines the sequence instead of reporting a gap" do
    id = "plug_seqep_#{System.unique_integer([:positive])}"
    first = StreamEpochs.new_epoch(id, :started)

    pid =
      start_supervised!({
        PluginPort,
        # a plugin that emits nothing: every line below is fed by hand, so
        # the epoch changes land at an exact point in the stream rather than
        # wherever the shell's output happens to be
        camera: camera(id), config: config(), index: 0, command: "exec sleep 30", tracker: self()
      })

    port = :sys.get_state(pid).port
    feed = fn line -> send(pid, {port, {:data, {:eol, line}}}) end

    feed.(v1_line(id, first, 0, [object("person", 0.9)]))
    feed.(v1_line(id, first, 1, [object("person", 0.9)]))
    assert_receive {:"$gen_cast", {:detections, _cam, _p, %Observation{sequence: 0}}}, 5_000
    assert_receive {:"$gen_cast", {:detections, _cam, _p, %Observation{sequence: 1}}}, 5_000

    second = StreamEpochs.new_epoch(id, :source_lost)

    # The plugin's last line under the retired epoch, refused as stale. It
    # consumed sequence 2 and no accepted line ever will — reporting that as a
    # lost frame on top of the refusal tells an operator about a gap that
    # never happened.
    feed.(v1_line(id, first, 2, [object("person", 0.9)]))
    # A plugin that restarts its counter per epoch, which the contract allows.
    feed.(v1_line(id, second, 0, [object("person", 0.9)]))
    assert_receive {:"$gen_cast", {:detections, _cam, _p, %Observation{sequence: 0}}}, 5_000
    assert :sys.get_state(pid).drops == %{stale_epoch: 1}

    # …and a plugin that keeps it monotonic across the boundary instead is
    # re-baselined the same way: the jump is another epoch's numbering, not a
    # loss.
    third = StreamEpochs.new_epoch(id, :stall_bounce)
    feed.(v1_line(id, third, 12, [object("person", 0.9)]))
    assert_receive {:"$gen_cast", {:detections, _cam, _p, %Observation{sequence: 12}}}, 5_000
    assert :sys.get_state(pid).drops == %{stale_epoch: 1}

    # Within one epoch a forward jump is still a gap: the re-baselining is
    # scoped to the boundary, not a blanket amnesty.
    feed.(v1_line(id, third, 14, [object("person", 0.9)]))
    assert_receive {:"$gen_cast", {:detections, _cam, _p, %Observation{sequence: 14}}}, 5_000
    assert :sys.get_state(pid).drops == %{stale_epoch: 1, sequence_gap: 1}
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

    # a per-camera plugin serves exactly one camera, so the envelope's
    # `camera_id` is at best redundant and at worst a plugin naming someone
    # else's camera: it must not reach what is stored and broadcast
    status =
      Jason.encode!(%{
        "spec" => "cairn.plugin",
        "version" => 1,
        "type" => "plugin.status",
        "camera_id" => "plug_hello_spoofed",
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
             tracker: self()}
          )

        assert_receive {:camera_status, ^id, info}, 5_000
        assert info.plugin_status == %{"state" => "ready", "detail" => "model loaded"}
        refute Map.has_key?(info.plugin_status, "camera_id")

        assert %{"name" => "fake-detect"} = :sys.get_state(pid).plugin
      end)

    # plugin-supplied values reach the log only through inspect/2
    assert log =~ ~s(plugin hello — "fake-detect" "9.9")
    assert log =~ "does not list protocol 1 in supported_versions"
  end

  test "a bignum pts or time_base drops the line and never the port" do
    id = "plug_bignum_#{System.unique_integer([:positive])}"
    epoch = StreamEpochs.new_epoch(id, :started)

    # Jason decodes JSON integer tokens at arbitrary precision, so this is a
    # bignum by the time the codec sees it. Unbounded, `Observation.media_ms/2`
    # raises ArithmeticError, which killed the port — and the respawned plugin
    # replays the line, walking the restart intensity up to app shutdown.
    huge = String.to_integer(String.duplicate("9", 400))

    command =
      printf([
        ~s({"pts": #{huge}, "dets": []}),
        v1_line(id, epoch, 1, [object("person", 0.9)], %{"pts" => huge}),
        v1_line(id, epoch, 2, [object("person", 0.9)], %{"time_base" => [huge, 1]}),
        v1_line(id, epoch, 3, [object("person", 0.9)])
      ]) <> "; exec sleep 30"

    pid =
      start_supervised!(
        {PluginPort,
         camera: camera(id), config: config(), index: 0, command: command, tracker: self()}
      )

    # ordered after all three: the port handles lines in order, so the last
    # line arriving proves the first three were dropped rather than pending
    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^id}, _policy, %Observation{sequence: 3}}},
                   5_000

    state = :sys.get_state(pid)
    assert %PluginPort{} = state
    # counted as contract violations, not as a codec crash
    assert state.drops == %{missing_pts_or_dets: 1, invalid_pts: 1, invalid_time_base: 1}
  end

  # The clock the tracker decides on is derived here, once per line
  # (`Cairn.ObservationClock`), because this is the only place the plugin's pts
  # and the host's monotonic clock are both in hand.
  test "every forwarded observation carries an at_ms on the host's monotonic clock" do
    id = "plug_at_ms_#{System.unique_integer([:positive])}"
    epoch = StreamEpochs.new_epoch(id, :started)

    command =
      printf([
        v1_line(id, epoch, 1, [object("person", 0.9)]),
        v1_line(id, epoch, 2, [object("person", 0.9)])
      ]) <> "; exec sleep 30"

    # the stamp has to land between these two readings, however slowly a
    # loaded machine gets through the receives — a fixed tolerance against
    # a `now` read afterwards would flake exactly there
    before = System.monotonic_time(:millisecond)

    start_supervised!(
      {PluginPort,
       camera: camera(id), config: config(), index: 0, command: command, tracker: self()}
    )

    assert_receive {:"$gen_cast",
                    {:detections, _cam, _policy, %Observation{sequence: 1} = first}},
                   5_000

    assert_receive {:"$gen_cast",
                    {:detections, _cam, _policy, %Observation{sequence: 2} = second}},
                   5_000

    now = System.monotonic_time(:millisecond)

    # on the host's scale, never ahead of it, and strictly increasing. These
    # two lines are printf'd back to back, so the pts spacing between them is
    # time the clamp is entitled to refuse — what it may never do is leave the
    # clock standing still
    assert first.at_ms >= before
    assert first.at_ms <= now
    assert second.at_ms > first.at_ms
    # the pts is carried through untouched beside it
    assert second.media_ms > first.media_ms
  end

  test "an observed_at far from host time is replaced with arrival time and counted" do
    id = "plug_skew_#{System.unique_integer([:positive])}"
    epoch = StreamEpochs.new_epoch(id, :started)
    now = DateTime.utc_now()

    command =
      printf([
        v1_line(id, epoch, 1, [object("person", 0.9)], %{
          "observed_at" => DateTime.to_iso8601(DateTime.add(now, 3_600, :second))
        }),
        v1_line(id, epoch, 2, [object("person", 0.9)], %{
          "observed_at" => DateTime.to_iso8601(DateTime.add(now, -5, :second))
        })
      ]) <> "; exec sleep 30"

    pid =
      start_supervised!(
        {PluginPort,
         camera: camera(id), config: config(), index: 0, command: command, tracker: self()}
      )

    # an hour-ahead plugin clock would future-date the event past every
    # retention sweep, and its labels/snapshot offsets with it
    assert_receive {:"$gen_cast",
                    {:detections, _cam, _policy, %Observation{sequence: 1} = skewed}},
                   5_000

    assert abs(DateTime.diff(skewed.observed_at, DateTime.utc_now(), :second)) < 30
    assert skewed.time_quality == :arrival

    # a plausible clock is left alone, still marked as the plugin's own
    assert_receive {:"$gen_cast", {:detections, _cam, _policy, %Observation{sequence: 2} = kept}},
                   5_000

    assert DateTime.diff(now, kept.observed_at, :second) == 5
    assert kept.time_quality == :source

    assert %{clock_skew: 1} = :sys.get_state(pid).drops
  end

  test "an epoch older than the one already announced is ignored" do
    id = "plug_order_#{System.unique_integer([:positive])}"
    StreamEpochs.new_epoch(id, :started)
    {path, command} = stdin_recorder()

    pid =
      start_supervised!(
        {PluginPort,
         camera: camera(id), config: config(), index: 0, command: command, tracker: self()}
      )

    assert [_started] = await_control(path, 1)
    second = StreamEpochs.new_epoch(id, :source_lost)
    assert [_, _, _] = await_control(path, 3)

    # a broadcast for an earlier mint, delivered late: the spawn-time ETS pull
    # racing a queued broadcast, or StreamEpochs' degraded caller-side path,
    # which has no ordering relation to the server's. Applying it would leave
    # the plugin stamping lines with a dead epoch while `current_epoch?/2`
    # compares against ETS — every observation dropped until the next respawn.
    send(pid, {:stream_epoch, id, ULID.generate(1), :source_lost})
    assert %PluginPort{epoch: {^second, :live}} = :sys.get_state(pid)

    # sentinel: the next real mint ends `second`, so nothing was written for
    # the stale one in between
    third = StreamEpochs.new_epoch(id, :stall_bounce)
    assert [_, _, _, ended, restarted] = await_control(path, 5)
    assert %{"type" => "stream.ended", "stream_epoch" => ^second} = ended
    assert %{"type" => "stream.started", "stream_epoch" => ^third} = restarted
  end

  # The capability buys a plugin nothing — the host tracks every object itself —
  # so declaring it is warned about once and changes nothing about the
  # observations, whose `track_id`s still arrive and are still ignored.
  test "an object_tracking declaration is warned about and changes no observation" do
    for {capabilities, declared} <- [{%{"object_tracking" => true}, true}, {%{}, false}] do
      id = "plug_cap_#{System.unique_integer([:positive])}"
      epoch = StreamEpochs.new_epoch(id, :started)

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

      objects = [Map.put(object("person", 0.9), "track_id", "t1")]
      command = printf([hello, v1_line(id, epoch, 1, objects)]) <> "; sleep 30"

      log =
        capture_log(fn ->
          start_supervised!(
            {PluginPort,
             camera: camera(id), config: config(), index: 0, command: command, tracker: self()},
            id: {:cap, declared}
          )

          assert_receive {:"$gen_cast",
                          {:detections, %Camera{id: ^id}, _policy,
                           %Observation{sequence: 1} = obs}},
                         5_000

          # the id is on the wire and reaches the observation; nothing acts on it
          assert [%{track_id: "t1"}] = obs.objects
        end)

      assert log =~ "declares object_tracking" == declared

      if declared do
        assert log =~ "host-side tracking is used and plugin track ids are ignored"
      end
    end
  end

  test "refresh swaps the policy without restarting the plugin process" do
    id = "plug_refresh_#{System.unique_integer([:positive])}"

    # the second line has to arrive after the refresh cast is handled, so the
    # fake's window is wide and the cast is flushed synchronously below
    command =
      printf([det_line(1, [det("person", "0.9", "[0, 0, 1, 1]")])]) <>
        "; sleep 5; " <>
        printf([det_line(2, [det("person", "0.9", "[0, 0, 1, 1]")])]) <> "; exec sleep 30"

    pid =
      start_supervised!(
        {PluginPort,
         camera: camera(id), config: config(), index: 0, command: command, tracker: self()}
      )

    assert_receive {:"$gen_cast", {:detections, %Camera{id: ^id}, policy, %Observation{pts: 1}}},
                   5_000

    assert policy.post == 10
    %PluginPort{port: port, os_pid: os_pid} = :sys.get_state(pid)

    # a camera field the argv never carried: the subprocess has nothing to
    # learn about it, so it keeps running
    widened = %Camera{camera(id) | post_window_seconds: 42}
    :ok = PluginPort.refresh(pid, widened, config())
    # flush the cast: it must be handled before the fake emits line 2
    _ = :sys.get_state(pid)

    assert_receive {:"$gen_cast",
                    {:detections, %Camera{id: ^id, post_window_seconds: 42}, %{post: 42},
                     %Observation{pts: 2}}},
                   10_000

    # same Port and same OS process: no respawn, no epoch re-announcement,
    # nothing the plugin can observe
    assert %PluginPort{port: ^port, os_pid: ^os_pid} = :sys.get_state(pid)
  end

  test "refresh during backoff swaps the policy and leaves the respawn alone" do
    id = "plug_bkoff_#{System.unique_integer([:positive])}"

    # exits at once and then waits out a backoff long enough that the respawn
    # cannot land inside this test
    pid =
      start_supervised!(
        {PluginPort,
         camera: camera(id),
         config: config(),
         index: 0,
         command: "exit 0",
         tracker: self(),
         backoff_min_ms: 60_000,
         backoff_max_ms: 60_000}
      )

    capture_log(fn ->
      %PluginPort{backoff_ms: backoff} = await_backoff(pid)

      widened = %Camera{camera(id) | post_window_seconds: 42}
      :ok = PluginPort.refresh(pid, widened, config())

      # there is no port to write to and the cast never looks for one: the
      # scheduled respawn, the backoff it will use and the epoch state are
      # all left exactly where the exit put them
      assert %PluginPort{
               port: nil,
               os_pid: nil,
               epoch: nil,
               backoff_ms: ^backoff,
               policy: %{post: 42},
               camera: %Camera{post_window_seconds: 42}
             } = :sys.get_state(pid)
    end)
  end

  # Flunks rather than returning the pre-exit state: "refreshed during
  # backoff" proves nothing if the port was still up.
  defp await_backoff(pid, attempts \\ 200) do
    case :sys.get_state(pid) do
      %PluginPort{port: nil} = state -> state
      _ when attempts > 0 -> Process.sleep(25) && await_backoff(pid, attempts - 1)
      _ -> flunk("plugin port never entered backoff")
    end
  end

  test "plugin exit triggers backoff respawn" do
    id = "plug_#{System.unique_integer([:positive])}"

    start_supervised!(
      {CameraTracker,
       camera_id: id,
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
       backoff_min_ms: 50,
       backoff_max_ms: 100}
    )

    assert_receive {:event_started, %Cairn.Event{camera_id: ^id}}, 5_000
    assert_receive {:event_updated, %Cairn.Event{camera_id: ^id}}, 5_000
  end
end
