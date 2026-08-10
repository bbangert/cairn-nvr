defmodule Cairn.MembraneE2ETest do
  @moduledoc """
  Plan task 3.6: the whole membrane stack on real video, in one VM.

      ffmpeg (MPEG-TS, one output) -> Cairn.Pipeline.Camera -> Picker
        -> Inference -> Cairn.Native.Host.push_frame/5 (in-VM NIF) -> DetectSink
        -> Observations -> Dispatch -> CameraTracker -> EventExtractor -> clip

  Nothing here is stubbed: the real NIF, the real canary, the real ffmpeg, the
  real ring buffer and extractor. `Cairn.Native.Host` is the application's own
  singleton because that is the name `Cairn.Pipeline.Camera` wires the sink to.

  Excluded by default (`test/test_helper.exs`) — CI's Elixir job builds no Rust.
  Run it with:

      mix test --only e2e_membrane

  Prerequisites, all asserted in `setup_all` rather than skipped around: the NIF
  at `priv/native/`, the `cairn-detect` release binary (the canary refuses to
  load a model it could not rehearse), a model, and ffmpeg/ffprobe.
  """

  use Cairn.DataCase, async: false

  alias Cairn.{CameraStatus, Config, Event, Events, StreamEpochs, Track}
  alias Cairn.Config.Camera
  alias Cairn.Native
  alias Cairn.Native.{Health, Host, Status}

  @moduletag :e2e_membrane
  @moduletag timeout: 600_000

  @model "plugins/cairn-detect/yolox_nano.onnx"
  @labels "plugins/cairn-detect/coco.names"
  @plugin "plugins/cairn-detect/target/release/cairn-detect"

  # Named rather than picked off a wildcard because the run depends on what is
  # in it: two cars and a potted plant, detected at every one of its nine
  # keyframes, in boxes that barely move — which is what makes the adoption
  # assertion below a statement about the tracker and not about the scene.
  # 2 s GOP, 20 fps, 18 s.
  @clip "data/events/reolink_main/08e15adf-b1c8-4217-b6a0-d201f253c54b_reolink_main_1785901116.mp4"

  setup_all do
    unless Native.available?() do
      raise "cairn-native is not loaded (#{inspect(Native.load_error())}); " <>
              "cargo build --release in plugins/cairn-native, then copy " <>
              "target/release/libcairn_native.so to priv/native/"
    end

    unless CairnOrt.available?() do
      raise "cairn-ort is not loaded (#{inspect(CairnOrt.load_error())}); " <>
              "cargo build --release in plugins/cairn-ort, then copy " <>
              "target/release/libcairn_ort.so to priv/native/"
    end

    for path <- [@model, @labels, @plugin, @clip] do
      unless File.exists?(path), do: raise("#{path} is missing")
    end

    # The canary probe-loads the model in a throwaway OS process before the NIF
    # is allowed near it, and a missing binary is a refusal rather than a skip.
    previous = Application.get_env(:cairn, Cairn.Native.Canary, [])
    Application.put_env(:cairn, Cairn.Native.Canary, Keyword.put(previous, :binary, @plugin))
    on_exit(fn -> Application.put_env(:cairn, Cairn.Native.Canary, previous) end)

    {:ok, status} =
      Host.configure(%{
        model: @model,
        labels: @labels,
        backend: "ort",
        decoder: "sw",
        sample_fps: 5
      })

    assert status.engine == :ready
    assert status.canary == :passed

    :ok
  end

  setup %{test: test} do
    id = "e2e_membrane_#{:erlang.phash2(test)}"

    camera = %Camera{
      id: id,
      rtsp_url: "file://" <> Path.absname(@clip),
      # Membrane cameras own no plugin process (`Cairn.Camera`), but a camera
      # with no plugin at all is a camera with detection off, and its pipeline
      # is built without a detect branch.
      plugin: {:group, "native"},
      # Under the clip's own scores: the cars sit at 0.56-0.63.
      min_score: %{"default" => 0.4},
      pipeline: :membrane
    }

    config = %Config{
      data_dir: Config.Server.get().data_dir,
      udp_base_port: 19_600,
      udp_port_range: 10,
      pre_window_seconds: 2,
      post_window_seconds: 3,
      max_event_seconds: 30,
      cameras: [camera]
    }

    on_exit(fn -> Host.close_stream(id) end)

    %{camera: camera, config: config, id: id}
  end

  test "a real clip through the membrane stack yields an event with a playable clip",
       %{camera: camera, config: config, id: id} do
    Event.subscribe()

    start_supervised!({Cairn.Camera, camera: camera, config: config, index: 0})

    assert_receive {:event_started, %Event{camera_id: ^id} = event}, 120_000

    # Mid-event, while access units are certainly reaching the model: the
    # engine is on a CPU backend, so `Cairn.Native.Health` has no baseline to
    # take a D-P5 ratio against and says so — `:not_applicable`, never a
    # verdict about an accelerator that is not there.
    assert Host.check_health() == :not_applicable

    # The check above closed a window; these two bracket the next one, which is
    # what the pass counts below are measured over. `inferences` only moves when
    # a cycle publishes, so counting without closing one measures nothing.
    started_at = System.monotonic_time(:millisecond)
    before = Health.snapshot().inferences

    # `Cairn.Native.Status` publishes through a cast to `Cairn.CameraStatus`, so
    # the surface trails the call that produced it.
    Status.publish()
    plugin_status = eventually(fn -> CameraStatus.get(id).plugin_status end)
    assert plugin_status["state"] == "ready"
    assert plugin_status["backend"] == "ort"
    # the operator-facing name: `Cairn.Native.Status` strips the path on purpose
    assert plugin_status["model"] == Path.basename(@model)
    assert plugin_status["health"] == "not_applicable"
    assert plugin_status["fps"] > 0.0

    assert_receive {:event_ended, %Event{camera_id: ^id, status: :finalized}}, 180_000

    row = wait_until(fn -> match?(%{status: :finalized}, Events.get(event.id)) end, event.id)

    on_exit(fn ->
      File.rm(row.path)
      if row.snapshot_path, do: File.rm(row.snapshot_path)
    end)

    assert row.bytes > 0
    assert File.exists?(row.path)
    assert Map.has_key?(row.labels["max_scores"], "car")

    # The clip is remuxed (`remux_clips` defaults on), so it must probe as a
    # real, seekable mp4 whose first sample is at zero — not a concatenation of
    # fragments that only a fragmented reader can open.
    {start_time, duration} = probe_format(row.path)
    assert_in_delta start_time, 0.0, 0.001
    assert duration > 1.0

    # Not an assertion about snapshots — it keeps the async snapshot task inside
    # this test's sandbox checkout, which it would otherwise outlive.
    row =
      wait_until(
        fn -> (Events.get(event.id) || %{snapshot_path: nil}).snapshot_path end,
        event.id
      )

    assert File.exists?(row.snapshot_path)

    assert Host.check_health() == :not_applicable
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    snapshot = Health.snapshot()
    passes = snapshot.inferences - before
    rate = passes * 1000 / elapsed_ms

    picker = picker_stats(id)

    report("""
    chain: source=#{Path.basename(@clip)} model=#{Path.basename(@model)} backend=ort
    measured over #{elapsed_ms} ms
    model passes: #{passes} (#{Float.round(rate, 2)}/s; Health says #{inspect(snapshot.stream_fps)})
    p50 per pass: #{snapshot.p50_ms} ms
    picker: #{inspect(picker)} (a drop costs detection until the next IDR)
    clip: #{row.path} #{row.bytes} bytes, #{duration}s, start_time #{start_time}
    labels: #{inspect(row.labels["max_scores"])}
    """)

    # What this measures now: the achieved rate is `sample_fps` (5), the crate's
    # own gate between `receive_frame` and `to_tensor`, and no longer the clip's
    # 2 s GOP (0.5/s, which is what a gate upstream of the decoder could reach).
    # A rate that fell back to the GOP rate means something is thinning access
    # units before the decoder again; a rate at the frame rate means no gate at
    # all.
    assert rate > 2.5
    assert rate < 6.0
  end

  test "a forced session restart mints a new epoch and the tracker adopts across it",
       %{camera: camera, config: config, id: id} do
    Event.subscribe()
    StreamEpochs.subscribe()
    attach_telemetry([:cairn, :tracker, :adopted])

    start_supervised!({Cairn.Camera, camera: camera, config: config, index: 0})

    assert_receive {:track_started, %Track{camera_id: ^id}}, 120_000

    # Two more keyframes' worth, so the tracks the cut suspends are ones the
    # tracker has confirmed more than once.
    Process.sleep(5_000)

    {:ok, epoch1} = StreamEpochs.current(id)
    live_before = live_track_ids(id)
    assert live_before != []

    pipeline = :sys.get_state(Cairn.Registry.whereis(id, :ffmpeg)).pipeline
    ref = Process.monitor(pipeline)
    Process.exit(pipeline, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}, 5_000

    # `Cairn.FFmpegPort` reads a dead pipeline as a lost decode session: backoff,
    # respawn, and a fresh epoch minted before the new port exists.
    assert_receive {:stream_epoch, ^id, epoch2, :source_lost}, 60_000
    refute epoch2 == epoch1

    # `Cairn.Tracker`'s rule, read rather than assumed: a detection in the new
    # epoch resumes a suspended track of the same label whose stored box it
    # overlaps by @stitch_iou (0.4) or more, for @adoption_window_ms (60_000)
    # after the cut. Same object_id, no `track_started`, no `track_ended`.
    assert_receive {:telemetry, [:cairn, :tracker, :adopted], %{count: adopted}, _meta}, 120_000
    assert adopted >= 1

    assert_receive {:track_updated, %Track{camera_id: ^id, epoch: ^epoch2} = resumed}, 60_000
    assert resumed.object_id in live_before

    ended = drain_ended(id)

    report("""
    epoch adoption: #{epoch1} -> #{epoch2} (:source_lost)
    live before the cut: #{length(live_before)}
    adopted on the first batch of the new epoch: #{adopted}
    ended :stream_reset: #{length(ended)}
    resumed: #{resumed.object_id} #{resumed.label} epoch #{resumed.epoch}
    """)

    refute resumed.object_id in Enum.map(ended, & &1.object_id)

    # `Cairn.CameraTracker.apply_epoch/3`: an in-flight event keeps running and
    # finalizes on its own timers — the reset ends neither it nor its clip.
    assert_receive {:event_ended, %Event{camera_id: ^id, status: :finalized} = ended_event},
                   180_000

    row =
      wait_until(
        fn -> match?(%{status: :finalized}, Events.get(ended_event.id)) end,
        ended_event.id
      )

    on_exit(fn ->
      File.rm(row.path)
      if row.snapshot_path, do: File.rm(row.snapshot_path)
    end)

    assert row.bytes > 0
    {start_time, duration} = probe_format(row.path)
    assert_in_delta start_time, 0.0, 0.001
    assert duration > 0.0

    # As in the first test: the snapshot task must not outlive the sandbox.
    row =
      wait_until(
        fn -> (Events.get(ended_event.id) || %{snapshot_path: nil}).snapshot_path end,
        ended_event.id
      )

    assert File.exists?(row.snapshot_path)
  end

  # -- helpers ----------------------------------------------------------------

  # Read out of the running element rather than asked for: the pipeline forwards
  # no child notification, and this is the harness's own reporting.
  defp picker_stats(camera_id) do
    with pipeline when is_pid(pipeline) <-
           :sys.get_state(Cairn.Registry.whereis(camera_id, :ffmpeg)).pipeline,
         %{children: %{picker: %{pid: pid}}} <- :sys.get_state(pipeline),
         %{internal_state: %{dropped: dropped, emitted: emitted}} <- :sys.get_state(pid) do
      %{dropped: dropped, emitted: emitted}
    else
      other -> %{unavailable: inspect(other)}
    end
  end

  # The tracker's live set is not readable from outside, so the ids come from
  # the lifecycle topic this test is already subscribed to: everything started
  # or updated and not since ended.
  defp live_track_ids(camera_id, acc \\ %{}) do
    receive do
      {kind, %Track{camera_id: ^camera_id} = track}
      when kind in [:track_started, :track_updated] ->
        live_track_ids(camera_id, Map.put(acc, track.object_id, track))

      {:track_ended, %Track{camera_id: ^camera_id} = track} ->
        live_track_ids(camera_id, Map.delete(acc, track.object_id))
    after
      0 -> Map.keys(acc)
    end
  end

  defp drain_ended(camera_id, acc \\ []) do
    receive do
      {:track_ended, %Track{camera_id: ^camera_id, end_reason: :stream_reset} = track} ->
        drain_ended(camera_id, [track | acc])
    after
      0 -> acc
    end
  end

  defp attach_telemetry(event) do
    test = self()
    handler = {__MODULE__, event, make_ref()}

    :telemetry.attach(
      handler,
      event,
      fn name, measurements, metadata, _config ->
        send(test, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp eventually(fun, attempts \\ 50) do
    case fun.() do
      nil when attempts > 0 ->
        Process.sleep(100)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end

  # The harness's own output: this test exists to be read as much as to pass.
  defp report(text), do: IO.puts("\n" <> text)

  defp probe_format(path) do
    {probe, 0} =
      System.cmd(
        "ffprobe",
        ~w(-v error -show_entries format=duration,start_time -of default=noprint_wrappers=1) ++
          [path]
      )

    fields =
      for line <- String.split(String.trim(probe), "\n"), into: %{} do
        [k, v] = String.split(line, "=", parts: 2)
        {k, elem(Float.parse(v), 0)}
      end

    {Map.fetch!(fields, "start_time"), Map.fetch!(fields, "duration")}
  end

  defp wait_until(fun, event_id, attempts \\ 300) do
    cond do
      fun.() ->
        Events.get(event_id)

      attempts == 0 ->
        flunk("condition never became true for event #{event_id}")

      true ->
        Process.sleep(100)
        wait_until(fun, event_id, attempts - 1)
    end
  end
end
