defmodule Cairn.Pipeline.ConformanceTest do
  @moduledoc """
  End-to-end interface-conformance tests for the membrane camera pipeline: they
  prove that a membrane-fed `Cairn.RingBuffer`/`Cairn.RTPHub` upholds the same
  downstream contracts the classic ffmpeg-stdout path does, driven through the
  real `Cairn.FFmpegPort` with a fake ffmpeg streaming a fixture to stdout.

  The classic path streams `testsrc*.fmp4`; the membrane path streams the same
  source re-containered as MPEG-TS (`testsrc*.ts`, `-c copy`). Equivalence is
  asserted on the fields consumers key on, never on bytes — the two segmenters
  differ (classic 1 s fragments at timescale 10240, the CMAF muxer 2 s at 30720).
  """

  use Cairn.DataCase, async: false

  import Phoenix.ConnTest

  alias Cairn.Config.Camera

  alias Cairn.{
    CameraStatus,
    Config,
    Event,
    Events,
    EventExtractor,
    FFmpegPort,
    RingBuffer,
    RTPHub,
    StreamEpochs
  }

  alias Cairn.MP4.Demuxer
  alias Cairn.RTP

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

  describe "interface #3: golden fragment shape (classic vs membrane, one source)" do
    test "the two segmenters agree on every field a consumer keys on" do
      classic = uid("classic")
      membrane = uid("membrane")

      start_ring(classic)
      start_ring(membrane)
      start_hub(membrane)

      start_port(classic_camera(classic), "#{@fake} #{@fmp4_long} 600 0")
      start_port(membrane_camera(membrane), "#{@fake} #{@ts_long} 600 0")

      assert_receive {:status, ^classic, :running}, 10_000
      assert_receive {:status, ^membrane, :running}, 10_000

      %{init: c_init, codec: c_codec, fragments: c_frags} = collect_stable(classic, 3)
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

      # ring re-stamps a fresh 0-based contiguous seq in both
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
      start_port(membrane_camera(id), "#{@fake} #{@ts} 600 0")
      assert_receive {:status, ^id, :running}, 10_000

      # Everything the membrane ring has buffered before the event opens is the
      # pre-window; the CMAF muxer cuts on keyframes, so each is keyframe-headed
      # and the extractor keeps the whole run.
      %{fragments: pre} = collect_stable(id, 2)
      pre_pts = Enum.map(pre, & &1.pts)

      cam = membrane_camera(id)
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
      start_port(membrane_camera(id), "#{@fake} #{@ts} 600 0")

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
      start_port(membrane_camera(id), "#{@fake} #{@ts} 600 0")
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

  describe "interface #5: camera-status lifecycle tuples (classic vs membrane)" do
    test "the membrane path publishes the same status tuple shape on cameras:status" do
      # The plan's interface #5 is "status/lifecycle tuple shapes"; those flow on
      # `CameraStatus`'s "cameras:status" topic (the dashboard/HA reader), not the
      # tracker's "events" topic — which the phase-1 membrane path, whose detect
      # branch is a stub, never touches. `set_status` is path-agnostic, so a
      # membrane camera must publish an identically-shaped tuple to a classic one.
      classic = uid("cstatus")
      membrane = uid("mstatus")

      CameraStatus.subscribe()

      start_ring(classic)
      start_ring(membrane)
      start_hub(membrane)

      # no status_fun override, so the real CameraStatus path runs
      start_status_port(classic_camera(classic), "#{@fake} #{@fmp4_long} 600 0")
      start_status_port(membrane_camera(membrane), "#{@fake} #{@ts_long} 600 0")

      c_info = assert_status_running(classic)
      m_info = assert_status_running(membrane)

      # same map shape (documented in Cairn.CameraStatus: status + probe +
      # plugin_status), status the same lifecycle atom
      assert Enum.sort(Map.keys(m_info)) == Enum.sort(Map.keys(c_info))
      assert m_info.status == :running
      assert Map.has_key?(m_info, :probe)
      assert Map.has_key?(m_info, :plugin_status)
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
      start_port(membrane_camera(id), "#{@fake} #{@ts} 2 42")

      assert_receive {:stream_epoch, ^id, first, :started}, 10_000
      assert_receive {:stream_epoch, ^id, second, :source_lost}, 15_000
      assert first != second

      # the respawned session's init segment carries the new epoch
      assert_receive {:init_segment, %{camera_id: ^id, epoch: ^second}}, 15_000
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp uid(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp classic_camera(id), do: %Camera{id: id, rtsp_url: "rtsp://127.0.0.1:554/x"}

  defp membrane_camera(id),
    do: %Camera{id: id, rtsp_url: "rtsp://127.0.0.1:554/x", pipeline: :membrane}

  # data_dir only matters to the EventExtractor here; the ports run a fake ffmpeg
  # via `command:`, so no argv, log path or UDP port is ever derived from it.
  defp config(dir) do
    %Config{
      data_dir: dir,
      udp_base_port: 19_700,
      udp_port_range: 10,
      stall_seconds: 30,
      remux_clips: false
    }
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
    start_supervised!({RTPHub, camera_id: id, port: nil}, id: {:hub, id})
  end

  defp start_port(cam, command) do
    test = self()

    start_supervised!(
      {FFmpegPort,
       camera: cam,
       config: config("tmp/conf_ports"),
       index: 0,
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
       index: 0,
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
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end
end
