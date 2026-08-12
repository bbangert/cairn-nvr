defmodule Cairn.Pipeline.ConformanceTest do
  @moduledoc """
  End-to-end interface-conformance tests for the camera pipeline: they prove
  that the pipeline-fed `Cairn.RingBuffer`/`Cairn.RTPHub` upholds the
  downstream contracts the deleted ffmpeg-stdout path established, driven
  through the real `Cairn.FFmpegPort` with a fake ffmpeg streaming a fixture
  to stdout.

  The reference is recorded, not run: `testsrc*.fmp4` is the old path's own
  ffmpeg output, replayed through the pure `Cairn.MP4.Demuxer` it consumed
  it with; the live path streams the same source re-containered as MPEG-TS
  (`testsrc*.ts`, `-c copy`). Equivalence is asserted on the fields
  consumers key on, never on bytes — the two segmenters differ (reference
  1 s fragments at timescale 10240, the CMAF muxer 2 s at 30720).
  """

  use Cairn.DataCase, async: false

  import Phoenix.ConnTest

  alias Cairn.Config.Camera

  alias Cairn.{
    CameraControl,
    CameraStatus,
    CameraTracker,
    CanaryStub,
    Config,
    Event,
    EventExtractor,
    Events,
    FFmpegPort,
    NativeStub,
    ObservationClock,
    PluginProtocol,
    RingBuffer,
    RTPHub,
    StreamEpochs,
    Track
  }

  alias Cairn.Detect.Dispatch
  alias Cairn.MP4.Demuxer
  alias Cairn.Native.Host
  alias Cairn.Pipeline.{DetectSink, Inference}
  alias Cairn.RTP
  alias Membrane.Buffer

  @endpoint CairnWeb.Endpoint

  @ts Path.absname("test/support/fixtures/media/testsrc.ts")
  @fmp4_long Path.absname("test/support/fixtures/media/testsrc_long.fmp4")
  @ts_long Path.absname("test/support/fixtures/media/testsrc_long.ts")
  @fake Path.absname("test/support/fake_ffmpeg.sh")

  @codec_format ~r/^avc1\.[0-9a-f]{6}$/

  # The mpegts muxer stamps the first PTS a fixed presentation offset in (~1.4 s);
  # classic fmp4 starts at 0. The golden test bounds the membrane offset two-sided
  # around it so a full-second timestamp regression cannot slip through.
  @ts_presentation_offset_s 1.4
  @ts_offset_tol_s 0.6
  # The CMAF muxer's configured segment floor (`RingBufferSink` pipeline runs it
  # at 2 s); used as the duration-sum bound instead of an observed fragment.
  @segment_ms 2_000

  # The one detection the "events" conformance tests drive both producers with.
  # `observed_at` is fixed rather than `utc_now/0` because every timestamp the
  # tracker publishes derives from it, so the two runs can be compared with `==`.
  @epoch "01J0000000000000000000000"
  @observed_at ~U[2026-07-26 12:00:00.500000Z]
  @detect_pts 90_000
  @detect_bbox [0.1, 0.1, 0.2, 0.4]
  @detect_policy %{pre: 5, post: 10, max: 300, max_unseen_ms: 3_000, max_live_tracks: 128}

  describe "interface #3: golden fragment shape (recorded reference vs pipeline)" do
    test "the two segmenters agree on every field a consumer keys on" do
      membrane = uid("membrane")

      start_ring(membrane)
      start_hub(membrane)

      # The reference side is the recorded fmp4 fixture — the deleted path's
      # own ffmpeg stdout — through the pure demuxer that path consumed it
      # with. No process needed: any chunking yields the same events.
      {_demuxer, ref_events} = Demuxer.push(Demuxer.new("reference"), File.read!(@fmp4_long))
      assert [{:init, %{data: c_init, codec: c_codec}} | ref_rest] = ref_events
      c_frags = for {:fragment, frag} <- ref_rest, do: frag

      start_port(camera(membrane), "#{@fake} #{@ts_long} 600 0")
      assert_receive {:status, ^membrane, :running}, 10_000

      %{init: m_init, codec: m_codec, fragments: m_frags} = collect_stable(membrane, 3)

      # both inits are valid ftyp+moov binaries
      for init <- [c_init, m_init] do
        assert match?(<<_::32, "ftyp", _::binary>>, init)
        assert :binary.match(init, "moov") != :nomatch
      end

      # same source stream, so identical RFC 6381 codec strings
      assert c_codec == m_codec
      assert c_codec =~ @codec_format

      # pts monotonic in both
      for frags <- [c_frags, m_frags] do
        pts = Enum.map(frags, & &1.pts)
        assert pts == Enum.sort(pts)
      end

      # timescales may differ (10240 vs muxer-derived 30720); both positive, and
      # it is pts/timescale (seconds) that must line up — consumers always divide
      c_ts = hd(c_frags).timescale
      m_ts = hd(m_frags).timescale
      assert c_ts > 0 and m_ts > 0

      c_secs = Enum.map(c_frags, &(&1.pts / &1.timescale))
      m_secs = Enum.map(m_frags, &(&1.pts / &1.timescale))

      # first-fragment pts sits the MPEG-TS presentation offset ahead of classic
      # (which starts at 0), bounded two-sided around that offset — not a
      # one-sided |delta| < 2 s that would wave a full-second regression through.
      assert_in_delta hd(m_secs), hd(c_secs) + @ts_presentation_offset_s, @ts_offset_tol_s

      # the two second-ranges overlap the same media window
      assert max(hd(c_secs), hd(m_secs)) <= min(List.last(c_secs), List.last(m_secs))

      # duration_ms sums: the muxer holds its final sub-2 s segment until an EOS
      # that never comes here (ffmpeg stays alive), so the membrane sum trails
      # classic by at most one segment. Bound by the muxer's configured segment
      # floor, not by whichever observed fragment happens to be largest.
      c_sum = Enum.sum(Enum.map(c_frags, & &1.duration_ms))
      m_sum = Enum.sum(Enum.map(m_frags, & &1.duration_ms))
      assert abs(m_sum - c_sum) <= @segment_ms

      # first fragment of each is keyframe-headed
      assert hd(c_frags).keyframe?
      assert hd(m_frags).keyframe?

      # a fresh 0-based contiguous seq on both sides: the demuxer's own
      # stamping on the reference, the ring's re-stamp on the live path
      for frags <- [c_frags, m_frags] do
        assert Enum.map(frags, & &1.seq) == Enum.to_list(0..(length(frags) - 1))
      end
    end
  end

  describe "interface #3: EventExtractor pre-window over a membrane-fed ring" do
    test "the drain captures the pre-window fragments into the clip, in order" do
      id = uid("prewin")
      dir = tmp_dir()

      start_ring(id)
      start_hub(id)
      start_port(camera(id), "#{@fake} #{@ts} 600 0")
      assert_receive {:status, ^id, :running}, 10_000

      # Everything the membrane ring has buffered before the event opens is the
      # pre-window; the CMAF muxer cuts on keyframes, so each is keyframe-headed
      # and the extractor keeps the whole run.
      %{fragments: pre} = collect_stable(id, 2)
      pre_pts = Enum.map(pre, & &1.pts)

      cam = camera(id)
      event = new_event(cam)

      pid =
        start_supervised!(
          {EventExtractor,
           camera: cam, event: event, config: config(dir), snapshot_fun: fn _row, _cfg -> :ok end},
          id: {:extractor, id}
        )

      ref = Process.monitor(pid)
      assert %{status: :active, path: path} = wait_row(event.id)

      # drain_and_subscribe handed the extractor the pre-window atomically; wait
      # until every drained fragment is written before finalizing.
      wait_until(fn -> :sys.get_state(pid).fragments == length(pre) end)

      EventExtractor.finalize(pid, %{event | ended_at: DateTime.utc_now(), status: :finalized})
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000

      # the clip re-parses as fmp4 and holds exactly the pre-window, same pts,
      # same order — nothing lost or duplicated at the drain/subscribe boundary
      {_d, events} = Demuxer.push(Demuxer.new("check"), File.read!(path))
      assert [{:init, _} | frag_events] = events
      out_pts = for {:fragment, f} <- frag_events, do: f.pts
      assert out_pts == pre_pts
      assert length(out_pts) >= 2
    end
  end

  describe "interface #4: RTP topic + gop_snapshot through the full pipeline" do
    test "packets flow on the hub topic and gop_snapshot replays from a keyframe" do
      id = uid("rtp")

      start_ring(id)
      start_hub(id)
      # subscribe before the port so no packet of the short media window is missed
      Phoenix.PubSub.subscribe(Cairn.PubSub, RTPHub.topic(id))
      start_port(camera(id), "#{@fake} #{@ts} 600 0")

      assert_receive {:rtp, %ExRTP.Packet{payload_type: 96}}, 10_000

      wait_until(fn -> match?([_ | _], RTPHub.gop_snapshot(id)) end)
      assert [first | _] = RTPHub.gop_snapshot(id)
      assert RTP.H264.keyframe_start?(first.payload)
    end
  end

  describe "interface #5: HLS viewer smoke over a membrane-fed ring" do
    test "playlist renders, init is ftyp, segment bytes start with moof" do
      id = uid("hls")

      start_ring(id)
      start_hub(id)
      start_port(camera(id), "#{@fake} #{@ts} 600 0")
      assert_receive {:status, ^id, :running}, 10_000

      %{fragments: frags} = collect_stable(id, 2)
      seq = List.last(frags).seq

      playlist = get(build_conn(), "/hls/#{id}/index.m3u8")
      assert response(playlist, 200)
      assert playlist.resp_body =~ "#EXTM3U"
      assert playlist.resp_body =~ ~s(#EXT-X-MAP:URI="init.mp4")
      assert playlist.resp_body =~ "#{seq}.m4s"

      init = get(build_conn(), "/hls/#{id}/init.mp4")
      assert response(init, 200)
      assert match?(<<_::32, "ftyp", _::binary>>, init.resp_body)

      segment = get(build_conn(), "/hls/#{id}/#{seq}.m4s")
      assert response(segment, 200)
      assert match?(<<_::32, "moof", _::binary>>, segment.resp_body)
    end
  end

  describe "interface #5: camera-status lifecycle tuples on cameras:status" do
    test "the pipeline path publishes the status tuple shape consumers key on" do
      # The plan's interface #5 conflates two topics. *Camera* status/lifecycle
      # flows on `CameraStatus`'s "cameras:status" topic (the dashboard/HA
      # reader); tracker/event lifecycle rides "events" and is asserted in the
      # describe below. The expected key set is the golden here — it was
      # proven equal to the classic path's before that path was deleted.
      membrane = uid("mstatus")

      CameraStatus.subscribe()

      start_ring(membrane)
      start_hub(membrane)

      # no status_fun override, so the real CameraStatus path runs
      start_status_port(camera(membrane), "#{@fake} #{@ts_long} 600 0")

      m_info = assert_status_running(membrane)

      # the literal map shape (documented in Cairn.CameraStatus: status +
      # probe + plugin_status), status the lifecycle atom
      assert Enum.sort(Map.keys(m_info)) == [:plugin_status, :probe, :status]
      assert m_info.status == :running
    end
  end

  describe "interface #5: tracker/event lifecycle tuples on \"events\" (wire reference vs pipeline)" do
    # "Same situation" is one person detection at one pts with one `observed_at`,
    # built two ways: `PluginProtocol.decode_line/2` over a literal wire line
    # plus the `ObservationClock` stamp — the retired plugin ports' own
    # construction, kept as the recorded-wire reference — and the real
    # `Inference`/`DetectSink` pair over a stubbed NIF. Each is delivered to a
    # real `CameraTracker`; both meet at `Cairn.Detect.Dispatch`.
    test "the same detection yields identical event and track broadcasts" do
      classic_id = uid("evclassic")
      membrane_id = uid("evmembrane")

      Event.subscribe()

      classic = start_tracker(classic_id)
      membrane = start_tracker(membrane_id)

      forward_classic(classic, classic_id)
      membrane |> start_infer_sink(membrane_id) |> feed_infer_sink()

      # both producers open the same two lifecycle frames, in the same order
      assert_receive {:track_started, %Track{camera_id: ^classic_id} = c_track}, 2_000
      assert_receive {:event_started, %Event{camera_id: ^classic_id} = c_event}, 2_000
      assert_receive {:track_started, %Track{camera_id: ^membrane_id} = m_track}, 2_000
      assert_receive {:event_started, %Event{camera_id: ^membrane_id} = m_event}, 2_000

      # …and every field of them agrees, bar the identities and the camera the
      # two runs cannot share. Compared whole rather than key by key, so a field
      # added to either struct has to be classified here before this passes.
      assert scrub_track(m_track) == scrub_track(c_track)
      assert scrub_event(m_event) == scrub_event(c_event)

      # `epoch` is what the tracker's suspend/adopt keys off (interface #6), so
      # it is asserted as a value and not only as "equal on both sides"
      assert c_track.epoch == @epoch and m_track.epoch == @epoch
      # every identity is the host's own on both paths — the NIF mints none and
      # the plugin's `track_id` is reserved, never adopted
      assert c_track.source == :host and m_track.source == :host
      assert c_track.plugin_track_id == nil and m_track.plugin_track_id == nil
    end

    test "an ended track carries the same tuple and end_reason on both paths" do
      classic_id = uid("endclassic")
      membrane_id = uid("endmembrane")

      Event.subscribe()

      classic = start_tracker(classic_id)
      membrane = start_tracker(membrane_id)

      forward_classic(classic, classic_id)
      sink = membrane |> start_infer_sink(membrane_id) |> feed_infer_sink()

      assert_receive {:track_started, %Track{camera_id: ^classic_id}}, 2_000
      assert_receive {:track_started, %Track{camera_id: ^membrane_id}}, 2_000

      # `:detection_disabled` is the one end reason reachable without waiting out
      # a liveness window, and it runs the same close-out path every other does.
      # The toggle is read on the next batch, so each path feeds one more.
      CameraControl.set(classic_id, %{detection_enabled: false})
      CameraControl.set(membrane_id, %{detection_enabled: false})

      forward_classic(classic, classic_id)
      feed_infer_sink(sink)

      assert_receive {:track_ended, %Track{camera_id: ^classic_id} = c_track}, 2_000
      assert_receive {:track_ended, %Track{camera_id: ^membrane_id} = m_track}, 2_000

      assert c_track.end_reason == :detection_disabled
      assert scrub_track(m_track) == scrub_track(c_track)
    end
  end

  describe "interface #6: stream-epoch semantics on the membrane path" do
    test "a lost source mints a fresh :source_lost epoch and re-tags the next init" do
      id = uid("epoch")

      StreamEpochs.subscribe()
      Phoenix.PubSub.subscribe(Cairn.PubSub, RingBuffer.topic(id))

      start_ring(id)
      start_hub(id)
      # streams, runs ~2 s (long enough for the pipeline to emit its init), then
      # exits non-zero — a lost decode session, same as a dead camera
      start_port(camera(id), "#{@fake} #{@ts} 2 42")

      assert_receive {:stream_epoch, ^id, first, :started}, 10_000
      assert_receive {:stream_epoch, ^id, second, :source_lost}, 15_000
      assert first != second

      # the respawned session's init segment carries the new epoch
      assert_receive {:init_segment, %{camera_id: ^id, epoch: ^second}}, 15_000
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp uid(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  # -- "events" conformance ---------------------------------------------------

  defp tracked_camera(id),
    do: %Camera{id: id, rtsp_url: "rtsp://127.0.0.1:554/x", min_score: %{"default" => 0.5}}

  defp start_tracker(camera_id) do
    on_exit(fn -> Cairn.EventCheckpoint.delete(camera_id) end)

    start_supervised!(
      {
        CameraTracker,
        # The clip pipeline is another interface's business; what is asserted here
        # is the broadcast, so the extractor is a process that does nothing.
        camera_id: camera_id,
        name: nil,
        start_extractor: fn _camera, _event ->
          {:ok, spawn(fn -> Process.sleep(:infinity) end)}
        end,
        finalize_extractor: fn _pid, _event -> :ok end
      },
      id: {:tracker, camera_id}
    )
  end

  # The wire reference's construction: the line decoded and stamped exactly
  # as the retired plugin ports did before they called the seam.
  defp forward_classic(tracker, camera_id) do
    {:objects, observation} = PluginProtocol.decode_line(plugin_line(camera_id), :group)

    {observation, _clock} =
      ObservationClock.stamp(
        ObservationClock.new(),
        observation,
        System.monotonic_time(:millisecond)
      )

    Dispatch.forward(tracked_camera(camera_id), @detect_policy, observation, tracker: tracker)
  end

  defp plugin_line(camera_id) do
    Jason.encode!(%{
      "spec" => "cairn.plugin",
      "version" => 1,
      "type" => "frame.objects",
      "camera_id" => camera_id,
      "stream_epoch" => @epoch,
      "sequence" => 1,
      "frame" => %{
        "pts" => @detect_pts,
        "observed_at" => DateTime.to_iso8601(@observed_at)
      },
      "objects" => [%{"label" => "person", "score" => 0.9, "bbox" => @detect_bbox}]
    })
  end

  # The membrane path's own construction: the real `Inference` element and
  # `DetectSink` over a stubbed NIF, so `Cairn.Native.Observations` and the
  # seam both run for real.
  defp start_infer_sink(tracker, camera_id) do
    :persistent_term.put(NativeStub.control(), %{
      test: self(),
      push_frame: fn _stream, _payload, _meta, _time_base -> {:ok, {[native_frame()], []}} end
    })

    on_exit(fn -> :persistent_term.erase(NativeStub.control()) end)

    host = :"conf_host_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Host,
       name: host,
       native_module: NativeStub,
       ort_module: Cairn.CairnOrtStub,
       canary_module: CanaryStub,
       config: %{model: "m.onnx", backend: "ort"}},
      id: host
    )

    inference =
      struct(Inference,
        session: {Host, host},
        stream_id: camera_id,
        stream_params: %{stream_epoch: @epoch},
        reopen_cooldown_ms: 0
      )

    {[], infer_state} = Inference.handle_init(%{}, inference)
    {_actions, infer_state} = Inference.handle_playing(%{}, infer_state)
    assert infer_state.stream == :open

    # the decoder's stream format always precedes its first buffer
    format = %Membrane.RawVideo{
      width: 2,
      height: 2,
      framerate: nil,
      pixel_format: :RGB,
      aligned: true
    }

    {[], infer_state} = Inference.handle_stream_format(:input, format, %{}, infer_state)

    sink =
      struct(DetectSink,
        camera: tracked_camera(camera_id),
        policy: @detect_policy,
        epoch: @epoch,
        tracker: tracker
      )

    {[], sink_state} = DetectSink.handle_init(%{}, sink)
    %{infer: infer_state, sink: sink_state}
  end

  defp feed_infer_sink(%{infer: infer_state, sink: sink_state}) do
    frame = NativeStub.decoded_frame()

    metadata =
      Map.take(frame, [
        :orig_width,
        :orig_height,
        :scale_x,
        :scale_y,
        :pad_w,
        :pad_h,
        :observed_at_ms,
        :motion
      ])

    {actions, infer_state} =
      Inference.handle_buffer(
        :input,
        %Buffer{payload: frame.payload, pts: Membrane.Time.seconds(1), metadata: metadata},
        %{},
        infer_state
      )

    # the Detections buffer crosses into the cairn-side sink, as in the pipeline
    assert [{:buffer, {:output, out}} | _] = actions
    {_actions, sink_state} = DetectSink.handle_buffer(:input, out, %{}, sink_state)

    %{infer: infer_state, sink: sink_state}
  end

  defp native_frame do
    %{
      pts: @detect_pts,
      observed_at_ms: DateTime.to_unix(@observed_at, :millisecond),
      inferred: true,
      infer_us: 12_000,
      objects: [
        %{
          label: "person",
          score: 0.9,
          bbox: @detect_bbox,
          track_id: nil,
          observation_kind: "detected"
        }
      ]
    }
  end

  # The identities two independent runs cannot share: the camera, and the ULID/
  # UUID the host mints per track and per event. Everything else must be equal.
  defp scrub_track(%Track{} = track), do: %{track | camera_id: nil, object_id: nil}

  defp scrub_event(%Event{} = event) do
    %{
      event
      | id: nil,
        camera_id: nil,
        labels: Enum.map(event.labels, &Map.put(&1, :object_id, nil)),
        trigger: event.trigger && Map.put(event.trigger, :object_id, nil)
    }
  end

  defp camera(id), do: %Camera{id: id, rtsp_url: "rtsp://127.0.0.1:554/x"}

  # data_dir only matters to the EventExtractor here; the ports run a fake ffmpeg
  # via `command:`, so no argv or log path is ever derived from it.
  defp config(dir) do
    %Config{data_dir: dir, stall_seconds: 30, remux_clips: false}
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "cairn_conf_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp start_ring(id) do
    start_supervised!({RingBuffer, camera_id: id, pre_window_seconds: 120}, id: {:ring, id})
  end

  defp start_hub(id) do
    start_supervised!({RTPHub, camera_id: id}, id: {:hub, id})
  end

  defp start_port(cam, command) do
    test = self()

    start_supervised!(
      {FFmpegPort,
       camera: cam,
       config: config("tmp/conf_ports"),
       command: command,
       backoff_min_ms: 50,
       backoff_max_ms: 200,
       watchdog_interval_ms: 5_000,
       status_fun: fn cam_id, status -> send(test, {:status, cam_id, status}) end},
      id: {:port, cam.id}
    )
  end

  # Like start_port/2 but with no status_fun override, so status transitions
  # travel the production CameraStatus path onto the "cameras:status" topic.
  defp start_status_port(cam, command) do
    start_supervised!(
      {FFmpegPort,
       camera: cam,
       config: config("tmp/conf_ports"),
       command: command,
       backoff_min_ms: 50,
       backoff_max_ms: 200,
       watchdog_interval_ms: 5_000},
      id: {:status_port, cam.id}
    )
  end

  defp assert_status_running(id) do
    assert_receive {:camera_status, ^id, %{status: :running} = info}, 10_000
    info
  end

  # Polls the ring until it holds at least `min` fragments AND that count is
  # stable across two reads — the muxer feeds the ring on real wall time, so a
  # premature read would see a partial run. Membrane fragment production settles
  # quickly here because the fake ffmpeg dumps the whole fixture at once.
  defp collect_stable(id, min, deadline_ms \\ 25_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_collect(id, min, -1, deadline)
  end

  defp do_collect(id, min, prev, deadline) do
    {:ok, %{fragments: frags} = data} = RingBuffer.fetch_recent(id, 1_000)
    n = length(frags)

    cond do
      n >= min and n == prev ->
        data

      System.monotonic_time(:millisecond) > deadline ->
        flunk("only #{n} fragments for #{id}, wanted a stable count >= #{min}")

      true ->
        Process.sleep(400)
        do_collect(id, min, n, deadline)
    end
  end

  defp new_event(cam) do
    %Event{
      id: Ecto.UUID.generate(),
      camera_id: cam.id,
      started_at: DateTime.utc_now(),
      max_scores: %{"person" => 0.9},
      max_score: 0.9,
      labels: [%{t: 0.0, label: "person", score: 0.9, object_id: 1}]
    }
  end

  defp wait_row(id, attempts \\ 200) do
    case Events.get(id) do
      nil when attempts > 0 ->
        Process.sleep(10)
        wait_row(id, attempts - 1)

      nil ->
        flunk("no index row for event #{id}")

      row ->
        row
    end
  end

  defp wait_until(fun, attempts \\ 300) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> retry(fun, attempts)
    end
  end

  defp retry(fun, attempts) do
    Process.sleep(20)
    wait_until(fun, attempts - 1)
  end
end
