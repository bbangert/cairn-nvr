defmodule Cairn.Pipeline.DualStreamTest do
  @moduledoc """
  Phase-3 acceptance for a camera with a `substream_url`, end to end through
  the real `Cairn.Pipeline.Camera` under its real `Cairn.PipelineOwner`: the
  detect branch is fed by the sub stream and the main tee keeps recording and
  RTP alone, the two streams' outages are independent, and a geometry the
  normalized-box contract does not survive is reported rather than silently
  drawn wrong.

  Both roles are driven through `Membrane.RTSPDualStream.MockRTSP`, reached by
  `Cairn.Pipeline.Camera`'s `rtsp_module:` seam: this process starts the
  sessions, *is* the camera for the duration, and can therefore put media on
  one role's pad without putting any on the other's — which is the whole point
  of the wiring under test.
  """

  use Cairn.DataCase, async: false

  alias Cairn.Config.Camera

  alias Cairn.{
    CameraTracker,
    Config,
    Event,
    NativeStub,
    PipelineOwner,
    RingBuffer,
    RTPHub,
    Snapshot,
    StreamEpochs,
    Track,
    TrackPath
  }

  alias Cairn.Native.Host
  alias Membrane.RTSPDualStream.MockRTSP
  alias Membrane.Testing.Pipeline, as: TestingPipeline

  # The fixture config's dual-stream camera. Its id is what makes
  # `Cairn.CameraTracker` resolve `:sub` as its detect role for real, out of
  # `Cairn.Config.Server`, rather than through a seam — and the tracker
  # dropping every sub-epoch batch as stale is exactly the failure a seam would
  # have hidden. The URIs below are this test's own; only the id is shared.
  @configured "cam_dual"

  # 1280x720 and 640x480 baseline SPS — 16:9 against 4:3, the mismatch task 3.6
  # is about. Both verified against `MediaCodecs.H264.NALU.SPS`.
  @sps_16_9 <<0x67, 0x42, 0x00, 0x1E, 0xF4, 0x02, 0x80, 0x2D, 0xC8>>
  @sps_4_3 <<0x67, 0x42, 0x00, 0x1E, 0xF4, 0x05, 0x01, 0xEC, 0x80>>
  @pps <<0x68, 0xCE, 0x3C, 0x80>>
  @idr <<0x65, 0x88, 0x84, 0x00>>

  @second 90_000
  @box [0.1, 0.1, 0.2, 0.4]

  describe "the detect branch" do
    @tag :capture_log
    test "is fed by the substream, and nothing taps the main tee" do
      stub_detection(@box)
      cam = start_dual(@configured)
      tracker(@configured)
      Event.subscribe()

      # Main media alone, as much of it as a session ever carries at once. It
      # reaches the recording side — the epoch is minted on the first buffer
      # through the main tagger — and it reaches nothing else.
      stream(cam.main, 0..7)
      assert_receive {:stream_epoch, @configured, :main, _main, :started}, 10_000

      # It reached the recording branch, and nothing else: no sub epoch was
      # minted and no batch was tracked, though the stub would have detected a
      # person in every frame it was given.
      assert await_fragments(@configured, 1) > 0
      refute_receive {:stream_epoch, @configured, :sub, _epoch, _reason}, 500
      refute_received {:track_started, _}

      # …and then one keyframe on the sub pad, which is all it takes.
      stream(cam.sub, 0..0)
      assert_receive {:stream_epoch, @configured, :sub, sub, :started}, 10_000
      assert_receive {:track_started, %Track{epoch: ^sub}}, 10_000
    end

    @tag :capture_log
    test "hangs off a source of its own when the main stream is an ffmpeg bridge" do
      id = uid("bridge")
      sub_uri = uri()
      MockRTSP.setup(sub_uri, [])

      cam =
        camera(id,
          ingest: :ffmpeg,
          substream_url: sub_uri,
          plugin: {:group, "g"}
        )

      pipeline = start_owner(cam).pipeline

      # Two source elements in one pipeline: the bridge owns main and knows
      # nothing about RTSP, the sub element runs sub-only.
      assert is_pid(await_child(pipeline, :source))
      assert is_pid(await_child(pipeline, :sub_source))
      assert is_pid(await_child(pipeline, :sub_tagger))

      stream(session_for(sub_uri), 0..0)
      assert_receive {:stream_epoch, ^id, :sub, _sub, :started}, 10_000
    end
  end

  describe "a substream outage" do
    @tag :capture_log
    test "costs the pipeline nothing and detection resumes on the next session" do
      stub_detection(@box)
      cam = start_dual(@configured)
      tracker(@configured)
      Event.subscribe()

      stream(cam.main, 0..7)
      stream(cam.sub, 0..0)
      assert_receive {:stream_epoch, @configured, :main, main, :started}, 10_000
      assert_receive {:stream_epoch, @configured, :sub, first, :started}, 10_000
      assert_receive {:track_started, %Track{epoch: ^first}}, 10_000

      # The sub camera goes away. Its own ladder owns the recovery, and the
      # owner is told the branch has produced nothing for two stall windows —
      # the tick that reads that is this process's, taken while the sub is
      # still down.
      {sub_client, sub_receiver} = cam.sub
      send(sub_receiver, {:rtsp, sub_client, :session_closed})
      wait_until(fn -> :sys.get_state(cam.owner).sources[:sub] in [:lost, :backoff] end)

      send(
        cam.owner,
        {:stats, %{last_buffer_at_ms: System.monotonic_time(:millisecond) - 60_000}}
      )

      send(cam.owner, :watchdog)
      _ = :sys.get_state(cam.owner)

      # Nothing was rebuilt, so the main stream's recording branch is the one
      # that was already running: same pipeline, same session, same epoch.
      assert :sys.get_state(cam.owner).pipeline == cam.pipeline
      assert Process.alive?(cam.pipeline)

      # …and the recording it feeds never paused: the same session, under the
      # same epoch, still filling the ring.
      recorded = await_fragments(@configured, 1)
      stream(cam.main, 8..15)
      assert await_fragments(@configured, recorded + 1) > recorded
      refute_receive {:stream_epoch, @configured, :main, _second, _reason}, 500
      assert StreamEpochs.current({@configured, :main}) == {:ok, main}

      # …and the sub's own reconnect is what fixes the sub: a fresh session
      # through the same long-lived branch, detecting again.
      stream(session_for(cam.uris.sub, 15_000), 10..10)
      assert_receive {:stream_epoch, @configured, :sub, second, :source_lost}, 10_000
      assert second != first

      # Updated and not started: the detect branch was never rebuilt, so the
      # tracker element still holds the identity it suspended at the boundary
      # and the same box adopts out of it.
      assert_receive {:track_updated, %Track{epoch: ^second}}, 10_000
    end
  end

  describe "aspect-ratio validation" do
    @tag :capture_log
    test "warns and emits telemetry once for a substream framed differently" do
      id = uid("aspect")
      telemetry(id)
      cam = start_dual(id)

      stream(cam.main, 0..0)
      stream(cam.sub, 0..0, @sps_4_3)

      assert_receive {:telemetry, [:cairn, :pipeline, :aspect_mismatch], measurements, meta},
                     10_000

      assert_in_delta measurements.main_aspect, 1280 / 720, 1.0e-6
      assert_in_delta measurements.sub_aspect, 640 / 480, 1.0e-6
      assert meta == %{camera_id: id, main: {1280, 720}, sub: {640, 480}}

      # Once per pair and not per session: a camera reconnecting every few
      # seconds re-emits both formats, and the misconfiguration has not
      # changed.
      {sub_client, sub_receiver} = cam.sub
      send(sub_receiver, {:rtsp, sub_client, :session_closed})
      stream(session_for(cam.uris.sub, 15_000), 10..10, @sps_4_3)
      assert_receive {:stream_epoch, ^id, :sub, _second, :source_lost}, 10_000

      refute_received {:telemetry, [:cairn, :pipeline, :aspect_mismatch], _m, _meta}
    end

    @tag :capture_log
    test "says nothing when the two streams frame the same scene" do
      id = uid("match")
      telemetry(id)
      cam = start_dual(id)

      stream(cam.main, 0..0)
      stream(cam.sub, 0..0)
      assert_receive {:stream_epoch, ^id, :sub, _sub, :started}, 10_000

      refute_received {:telemetry, [:cairn, :pipeline, :aspect_mismatch], _m, _meta}
    end

    # The other half of 3.6, and the reason the check above is a warning rather
    # than a refusal: a box measured on the sub frame is drawn on an artifact
    # cut from main, and no code anywhere rescales it. What makes that work is
    # that every stored box is a fraction of its own frame — so this asserts
    # the fractions survive the sidecar and land on the same picture content at
    # either resolution.
    test "a sub-frame-normalized box lands on the same place in a main-stream artifact" do
      # A person 128 px in and 192 px wide on a 640x360 substream frame.
      sub = %{w: 640, h: 360}
      main = %{w: 1920, h: 1080}
      pixels = %{x: 128, y: 72, w: 192, h: 144}

      bbox = [
        pixels.x / sub.w,
        pixels.y / sub.h,
        pixels.w / sub.w,
        pixels.h / sub.h
      ]

      # `Cairn.Snapshot` is where a box and a frame finally meet on this side:
      # the overlay is expressed in `iw`/`ih` multiples, so ffmpeg resolves it
      # against whatever frame the clip actually holds — main's.
      row = %{
        id: Ecto.UUID.generate(),
        path: "/nonexistent.mp4",
        labels: %{"trigger" => %{"t" => 0.0, "label" => "person", "bbox" => bbox, "score" => 0.9}},
        started_at: DateTime.utc_now()
      }

      vf = video_filter(Snapshot.args(row, "/tmp/x.jpg", 0.0))
      assert [x, y, w, h] = drawbox(vf)

      # The same fraction of the main frame is the same content, to the pixel:
      # the sub's 128 px is 1/5 of 640, and 1/5 of 1920 is 384.
      scale = main.w / sub.w
      assert_in_delta x * main.w, pixels.x * scale, 0.5
      assert_in_delta y * main.h, pixels.y * scale, 0.5
      assert_in_delta w * main.w, pixels.w * scale, 0.5
      assert_in_delta h * main.h, pixels.h * scale, 0.5

      # And the dense path the browser draws from carries the same fractions:
      # `Cairn.TrackPath` quantizes to 1/10_000 of the frame and nothing else,
      # so the overlay's `box * videoWidth` is this arithmetic again.
      {:ok, decoded} =
        %{event_id: row.id, camera_id: @configured}
        |> TrackPath.encode([{0, [{"obj", "person", bbox, false}]}])
        |> TrackPath.decode()

      assert [%{"x" => [qx], "y" => [qy], "w" => [qw], "h" => [qh]}] = decoded["tracks"]
      assert_in_delta qx / 10_000 * main.w, pixels.x * scale, 0.5
      assert_in_delta qy / 10_000 * main.h, pixels.y * scale, 0.5
      assert_in_delta qw / 10_000 * main.w, pixels.w * scale, 0.5
      assert_in_delta qh / 10_000 * main.h, pixels.h * scale, 0.5
    end
  end

  # -- the camera under test ----------------------------------------------------

  defp uid(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp uri, do: "rtsp://127.0.0.1:554/cam#{System.unique_integer([:positive])}"

  defp config, do: %Config{data_dir: "tmp/dual_stream", stall_seconds: 30}

  defp camera(id, opts) do
    struct!(
      %Camera{id: id, rtsp_url: uri(), min_score: %{"default" => 0.5}},
      opts
    )
  end

  # Both roles live on the rtsp ingest: one source element, two sessions, two
  # mock cameras this process answers for.
  defp start_dual(id) do
    uris = %{main: uri(), sub: uri()}
    for {_role, u} <- uris, do: MockRTSP.setup(u, [])

    cam =
      camera(id,
        ingest: :rtsp,
        rtsp_url: uris.main,
        substream_url: uris.sub,
        plugin: {:group, "g"}
      )

    started = start_owner(cam)

    Map.merge(started, %{
      uris: uris,
      main: session_for(uris.main),
      sub: session_for(uris.sub)
    })
  end

  defp start_owner(cam) do
    start_supervised!({RingBuffer, camera_id: cam.id, pre_window_seconds: 120},
      id: {:ring, cam.id}
    )

    start_supervised!({RTPHub, camera_id: cam.id}, id: {:hub, cam.id})

    # Before the owner: the first mint rides the first buffer, and this process
    # is the reference for every boundary asserted here.
    StreamEpochs.subscribe()

    owner =
      start_supervised!(
        {
          PipelineOwner,
          # Every escalation in this file is driven; the timer is kept out of
          # the way rather than raced with.
          camera: cam,
          config: config(),
          rtsp_module: MockRTSP,
          backoff_min_ms: 20,
          backoff_max_ms: 100,
          watchdog_interval_ms: 60_000,
          flush_grace_ms: 100,
          status_fun: fn _id, _status -> :ok end
        },
        id: {:owner, cam.id}
      )

    %{camera: cam, owner: owner, pipeline: await_pipeline(owner)}
  end

  # A selective receive rather than `assert_receive`: the other role's session
  # must stay in the mailbox for its own turn.
  defp session_for(uri, timeout \\ 2_000) do
    receive do
      {:rtsp_started, ^uri, client, opts} -> {client, opts[:receiver]}
    after
      timeout -> flunk("no session started for #{uri} within #{timeout} ms")
    end
  end

  # One keyframe access unit per second of `seconds`, as the rtsp client
  # delivers them: bare NALs, pts on the session's 90 kHz clock. Every AU is a
  # keyframe, so nothing is dropped by the source's drop-until-IDR gate and the
  # CMAF muxer has a cut point wherever it wants one.
  defp stream(session, seconds, sps \\ @sps_16_9) do
    {client, receiver} = session

    for s <- seconds do
      send(receiver, {:rtsp, client, {"video", {[sps, @pps, @idr], s * @second, true, 1}}})
    end

    # The element consumes its mailbox in order, so one round trip after the
    # last send is every send having been handled.
    _ = :sys.get_state(receiver)
    :ok
  end

  # The ring's fragment count once it has reached `least`. The CMAF muxer cuts
  # on the keyframe that takes a segment past its 2 s floor and holds the tail,
  # so a count is only meaningful once the media that would produce it has been
  # through parser and muxer.
  defp await_fragments(camera_id, least) do
    wait_until(fn -> fragment_count(camera_id) >= least end)
    fragment_count(camera_id)
  end

  defp fragment_count(camera_id) do
    {:ok, %{fragments: fragments}} = RingBuffer.fetch_recent(camera_id, 1_000)
    length(fragments)
  end

  defp wait_until(fun, attempts \\ 300) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> retry(fun, attempts)
    end
  end

  defp retry(fun, attempts) do
    Process.sleep(10)
    wait_until(fun, attempts - 1)
  end

  defp await_pipeline(owner, attempts \\ 300) do
    case :sys.get_state(owner).pipeline do
      pid when is_pid(pid) ->
        pid

      _ when attempts > 0 ->
        Process.sleep(10)
        await_pipeline(owner, attempts - 1)

      _ ->
        flunk("no pipeline for #{inspect(owner)}")
    end
  end

  defp await_child(pipeline, child, attempts \\ 300) do
    case TestingPipeline.get_child_pid(pipeline, child) do
      {:ok, pid} ->
        pid

      {:error, _reason} when attempts > 0 ->
        Process.sleep(10)
        await_child(pipeline, child, attempts - 1)

      {:error, reason} ->
        flunk("#{inspect(child)} never appeared: #{inspect(reason)}")
    end
  end

  # -- the tracker and the detect branch's native halves ------------------------

  # Registered, because the pipeline's own `Cairn.Pipeline.TrackSink` resolves
  # the camera's tracker through `Cairn.Detect.Dispatch` and knows no pid.
  defp tracker(camera_id) do
    on_exit(fn -> Cairn.EventCheckpoint.delete(camera_id) end)

    # `Cairn.CameraTracker.tracked/3` starts one under the application's own
    # pool for any camera that has none, and it outlives the test that
    # provoked it — carrying that test's epoch, which would make this one's
    # batches stale. Two tests here share `@configured`, so the pool is cleared
    # on the way in and on the way out.
    reap_tracker(camera_id)
    on_exit(fn -> reap_tracker(camera_id) end)

    start_supervised!(
      {CameraTracker,
       camera_id: camera_id,
       name: Cairn.Registry.via(camera_id, :camera_tracker),
       start_extractor: fn _camera, _event ->
         {:ok, spawn(fn -> Process.sleep(:infinity) end)}
       end,
       finalize_extractor: fn _pid, _event -> :ok end},
      id: {:tracker, camera_id}
    )
  end

  defp reap_tracker(camera_id) do
    case Cairn.Registry.whereis(camera_id, :camera_tracker) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Cairn.TrackerSupervisor.Pool, pid)
    end

    Cairn.Registry.await_unregistered(camera_id, :camera_tracker)
  end

  # The decode and inference NIFs, stubbed under the name the pipeline builds
  # them with — CI has neither library nor model, and the pipeline exposes no
  # seam for either, so a test that needs a real detection has to *be* the host
  # for the duration (`Cairn.Pipeline.ReconnectIntegrationTest` does the same).
  defp stub_detection(bbox) do
    :persistent_term.put(NativeStub.control(), %{
      test: nil,
      push_frame: fn _stream, _payload, _meta, _time_base -> {:ok, {[frame(bbox)], []}} end
    })

    on_exit(fn -> :persistent_term.erase(NativeStub.control()) end)

    :ok = Supervisor.terminate_child(Cairn.Supervisor, Host)

    on_exit(fn ->
      case Process.whereis(Host) do
        nil -> :ok
        stub -> GenServer.stop(stub)
      end

      {:ok, _restored} = Supervisor.restart_child(Cairn.Supervisor, Host)
    end)

    start_supervised!(
      {Host,
       name: Host,
       native_module: NativeStub,
       ort_module: Cairn.CairnOrtStub,
       canary_module: Cairn.CanaryStub,
       config: %{model: "m.onnx", backend: "ort"}},
      id: :stub_host
    )
  end

  defp frame(bbox) do
    %{
      pts: 0,
      observed_at_ms: System.os_time(:millisecond),
      inferred: true,
      infer_us: 12_000,
      objects: [
        %{label: "person", score: 0.9, bbox: bbox, track_id: nil, observation_kind: "detected"}
      ]
    }
  end

  defp telemetry(camera_id) do
    test = self()
    handler = "dual-#{camera_id}"

    :telemetry.attach(
      handler,
      [:cairn, :pipeline, :aspect_mismatch],
      fn event, measurements, meta, _config ->
        if meta.camera_id == camera_id, do: send(test, {:telemetry, event, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # -- the snapshot filtergraph -------------------------------------------------

  defp video_filter(args), do: Enum.at(args, Enum.find_index(args, &(&1 == "-vf")) + 1)

  # The four `iw`/`ih` fractions out of the drawbox filter, in x, y, w, h order.
  defp drawbox(vf) do
    Regex.run(
      ~r/drawbox=x=iw\*([\d.]+):y=ih\*([\d.]+):w=iw\*([\d.]+):h=ih\*([\d.]+)/,
      vf,
      capture: :all_but_first
    )
    |> Enum.map(&String.to_float/1)
  end
end
