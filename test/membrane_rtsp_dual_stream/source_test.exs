defmodule Membrane.RTSPDualStream.SourceTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad, as: Pad

  alias Membrane.Buffer
  alias Membrane.RTSPDualStream.Event.StreamClosed
  alias Membrane.RTSPDualStream.MockRTSP
  alias Membrane.RTSPDualStream.Source
  alias Membrane.Testing

  # 1280x720 baseline SPS, verified against MediaCodecs.H264.NALU.SPS.
  @sps <<0x67, 0x42, 0x00, 0x1E, 0xF4, 0x02, 0x80, 0x2D, 0xC8>>
  @pps <<0x68, 0xCE, 0x3C, 0x80>>
  @idr <<0x65, 0x88, 0x84, 0x00>>
  @non_idr <<0x41, 0x9A, 0x00>>

  @keyframe_au [@sps, @pps, @idr]

  defp uri, do: "rtsp://127.0.0.1:554/cam#{System.unique_integer([:positive])}"

  defp start_source(opts) do
    uri = uri()
    MockRTSP.setup(uri, opts)

    source = %Source{
      stream_uri: uri,
      rtsp_module: MockRTSP,
      backoff_min_ms: Keyword.get(opts, :backoff_min_ms, 50),
      backoff_max_ms: Keyword.get(opts, :backoff_max_ms, 200)
    }

    Testing.Pipeline.start_link_supervised!(
      spec:
        child(:source, source)
        |> via_out(Pad.ref(:output, :main))
        |> child(:sink, Testing.Sink)
    )
  end

  # Both roles live, each with its own mock camera (`main:` / `sub:` carry
  # that role's MockRTSP options) and its own sink, so an assertion on one
  # role's pad cannot be satisfied by the other's traffic.
  defp start_dual(opts) do
    uris = %{main: uri(), sub: uri()}
    for {role, uri} <- uris, do: MockRTSP.setup(uri, Keyword.get(opts, role, []))

    source = %Source{
      stream_uri: uris.main,
      substream_uri: uris.sub,
      rtsp_module: MockRTSP,
      backoff_min_ms: Keyword.get(opts, :backoff_min_ms, 50),
      backoff_max_ms: Keyword.get(opts, :backoff_max_ms, 200)
    }

    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec: [
          child(:source, source),
          get_child(:source) |> via_out(Pad.ref(:output, :main)) |> child(:main, Testing.Sink),
          get_child(:source) |> via_out(Pad.ref(:output, :sub)) |> child(:sub, Testing.Sink)
        ]
      )

    {pipeline, uris}
  end

  # The element's own pid, learned the way the library learns it: from the
  # `receiver:` it was started with.
  defp session(timeout \\ 2_000) do
    assert_receive {:rtsp_started, _uri, client, opts}, timeout
    {client, opts[:receiver], opts}
  end

  # A selective receive rather than `assert_receive`: the other role's
  # sessions must stay in the mailbox for its own assertions.
  defp session_for(uri, timeout \\ 2_000) do
    receive do
      {:rtsp_started, ^uri, client, opts} -> {client, opts[:receiver]}
    after
      timeout -> flunk("no session started for #{uri} within #{timeout} ms")
    end
  end

  defp refute_session(uri, timeout) do
    receive do
      {:rtsp_started, ^uri, _client, _opts} -> flunk("unexpected session for #{uri}")
    after
      timeout -> :ok
    end
  end

  defp keyframe(source, client, pts) do
    send(source, {:rtsp, client, {"video", {@keyframe_au, pts, true, 1}}})
  end

  describe "a live session" do
    test "connects video-only, announces its tracks, and drops until the first IDR" do
      pipeline = start_source([])
      {client, source, opts} = session()

      assert opts[:transport] == :tcp
      # Audio would be SETUP, received and depayloaded just to be discarded
      # here — and a broken audio track must not refuse a valid session.
      assert opts[:allowed_media_types] == [:video]

      assert_pipeline_notified(pipeline, :source, {:stream_connected, :main, tracks})
      assert tracks == MockRTSP.default_tracks()

      send(source, {:rtsp, client, {"video", {[@non_idr], 0, false, 1}}})
      refute_sink_buffer(pipeline, :sink, %Buffer{}, 200)

      keyframe(source, client, 90_000)

      assert_sink_stream_format(pipeline, :sink, %Membrane.H264{
        alignment: :au,
        stream_structure: :annexb,
        width: 1280,
        height: 720,
        profile: :baseline
      })

      framed = <<0, 0, 0, 1>> <> @sps <> <<0, 0, 0, 1>> <> @pps <> <<0, 0, 0, 1>> <> @idr

      assert_sink_buffer(pipeline, :sink, %Buffer{
        payload: ^framed,
        pts: 1_000_000_000,
        metadata: %{keyframe?: true}
      })
    end

    test "fans a batch out in order, framing a bare NALU as readily as a list" do
      pipeline = start_source([])
      {client, source, _opts} = session()

      keyframe(source, client, 0)
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: 0})

      send(
        source,
        {:rtsp, client, {"video", [{[@non_idr], 93_000, false, 3}, {@non_idr, 96_000, false, 4}]}}
      )

      bare = <<0, 0, 0, 1>> <> @non_idr
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: 1_033_333_333, payload: ^bare})
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: 1_066_666_666, payload: ^bare})
    end

    test "ignores tracks other than the negotiated video path" do
      pipeline = start_source([])
      {client, source, _opts} = session()

      send(source, {:rtsp, client, {"audio", {[<<0xFF>>], 0, true, 1}}})
      refute_sink_buffer(pipeline, :sink, %Buffer{}, 200)
    end

    test "keeps dropping when the first keyframe carries no SPS" do
      pipeline = start_source([])
      {client, source, _opts} = session()

      send(source, {:rtsp, client, {"video", {[@idr], 0, true, 1}}})
      refute_sink_buffer(pipeline, :sink, %Buffer{}, 200)

      keyframe(source, client, 90_000)
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: 1_000_000_000})
    end

    test "forwards a mid-session discontinuity without ending the session" do
      pipeline = start_source([])
      {client, source, _opts} = session()

      keyframe(source, client, 0)
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: 0})

      send(source, {:rtsp, client, :discontinuity})
      assert_sink_event(pipeline, :sink, %Membrane.Event.Discontinuity{})

      send(source, {:rtsp, client, {"video", {[@non_idr], 3_000, false, 2}}})
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: 33_333_333})
      refute_receive {:rtsp_started, _uri, _client, _opts}, 100
    end
  end

  describe "session death" do
    test "closes the stream downstream, reaps the client, and re-arms on the next session" do
      pipeline = start_source([])
      {client, source, _opts} = session()

      reaped = Process.monitor(client)

      keyframe(source, client, 0)
      assert_sink_stream_format(pipeline, :sink, %Membrane.H264{width: 1280})
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: 0})

      send(source, {:rtsp, client, :session_closed})

      assert_sink_event(pipeline, :sink, %StreamClosed{})
      assert_pipeline_notified(pipeline, :source, {:stream_lost, :main})

      # The library's stop/1 leaves the client process alive by design; the
      # element must end it or leak one process per session.
      assert_receive {:DOWN, ^reaped, :process, _pid, _reason}, 5_000

      {client2, ^source, _opts2} = session()
      assert client2 != client
      assert_pipeline_notified(pipeline, :source, {:stream_connected, :main, _tracks})

      send(source, {:rtsp, client2, {"video", {[@non_idr], 4_500, false, 3}}})
      refute_sink_buffer(pipeline, :sink, %Buffer{}, 200)

      # A session boundary is a format boundary: re-emitted even though it
      # is byte-identical to the previous session's.
      keyframe(source, client2, 9_000)
      assert_sink_stream_format(pipeline, :sink, %Membrane.H264{width: 1280})
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: 100_000_000})
    end

    test "ignores a dead session's late delivery" do
      pipeline = start_source([])
      {client, source, _opts} = session()

      keyframe(source, client, 0)
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: 0})

      send(source, {:rtsp, client, :session_closed})
      {client2, ^source, _opts} = session()
      assert client2 != client

      keyframe(source, client, 90_000)
      refute_sink_buffer(pipeline, :sink, %Buffer{pts: 1_000_000_000}, 200)
    end
  end

  describe "refusals" do
    test "a camera advertising no video track" do
      pipeline = start_source(tracks: [], backoff_min_ms: 20)
      {_client, _source, _opts} = session()

      assert_pipeline_notified(pipeline, :source, {:stream_backoff, :main, :no_video_track})
      # ...and the refusal is a backoff, not a stop: the retry lands.
      assert {_client2, _source, _opts} = session()
    end

    test "a video track that is not H.264, carrying the camera's own spelling" do
      tracks = [
        %{
          control_path: "video",
          type: :video,
          fmtp: nil,
          rtpmap: %{encoding: "h265", clock_rate: 90_000}
        }
      ]

      pipeline = start_source(tracks: tracks, backoff_min_ms: 20)
      {_client, _source, _opts} = session()

      assert_pipeline_notified(
        pipeline,
        :source,
        {:stream_backoff, :main, {:unsupported_codec, "h265"}}
      )

      assert {_client2, _source, _opts} = session()
    end

    test "a connect that exits the caller instead of returning an error" do
      pipeline = start_source(connect: fn _attempt -> :exit end, backoff_min_ms: 20)
      {_client, _source, _opts} = session()

      assert_pipeline_notified(pipeline, :source, {:stream_backoff, :main, {:exit, _reason}})
      assert {_client2, _source, _opts} = session()
    end
  end

  describe "graceful stop" do
    test "ends the stream, reaps the session, and never reconnects again" do
      pipeline = start_source(backoff_min_ms: 20)
      {client, source, _opts} = session()

      reaped = Process.monitor(client)

      keyframe(source, client, 0)
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: 0})

      Testing.Pipeline.notify_child(pipeline, :source, :eos)

      # EOS is what flushes a downstream muxer's held tail.
      assert_end_of_stream(pipeline, :sink)
      assert_receive {:DOWN, ^reaped, :process, _pid, _reason}, 5_000

      # …and the element is not reusable: a session death after the stop
      # starts nothing.
      send(source, {:rtsp, client, :session_closed})
      refute_receive {:rtsp_started, _uri, _client2, _opts}, 300
    end

    test "cancels a pending reconnect instead of stopping a timer that never ran" do
      pipeline = start_source(connect: fn _attempt -> {:error, :refused} end, backoff_min_ms: 500)
      {_client, _source, _opts} = session()

      assert_pipeline_notified(pipeline, :source, {:stream_backoff, :main, :refused})

      # A source that never emitted has no stream to end; the point is that
      # the pending retry timer is stopped rather than left to fire.
      Testing.Pipeline.notify_child(pipeline, :source, :eos)
      refute_receive {:rtsp_started, _uri, _client, _opts}, 800
    end
  end

  describe "backoff" do
    test "doubles between attempts" do
      start_source(
        connect: fn _attempt -> {:error, :refused} end,
        backoff_min_ms: 100,
        backoff_max_ms: 100_000
      )

      {_client, _source, _opts} = session()
      started = System.monotonic_time(:millisecond)

      # The three delays before attempts 2..4 are 100, 200 and 400 ms, which
      # the jitter can halve but not more — 350 ms is the ladder's floor.
      for _attempt <- 1..3, do: assert({_c, _s, _o} = session())
      assert System.monotonic_time(:millisecond) - started >= 350
    end

    test "stops doubling at the cap" do
      start_source(
        connect: fn _attempt -> {:error, :refused} end,
        backoff_min_ms: 20,
        backoff_max_ms: 40
      )

      {_client, _source, _opts} = session()
      started = System.monotonic_time(:millisecond)

      # Capped, the seven delays cannot exceed 30 + 6 * 60 = 390 ms; the same
      # seven doubling freely could not finish inside 1270 ms.
      for _attempt <- 1..7, do: assert({_c, _s, _o} = session())
      assert System.monotonic_time(:millisecond) - started < 800
    end

    test "resets to the minimum once media flows" do
      pipeline =
        start_source(
          connect: fn attempt -> if attempt < 3, do: {:error, :refused}, else: :ok end,
          backoff_min_ms: 100,
          backoff_max_ms: 100_000
        )

      for _attempt <- 0..2, do: assert({_c, _s, _o} = session())
      {client, source, _opts} = session()

      keyframe(source, client, 0)
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: 0})

      send(source, {:rtsp, client, :session_closed})
      # Back at 100 ms the next attempt lands within 150 ms; had the three
      # refusals stood, the ladder would be at 1600 ms.
      assert {_client2, _source, _opts} = session(300)
    end
  end

  describe "both roles" do
    test "connect as two sessions, each pad carrying only its own" do
      {pipeline, uris} = start_dual([])
      {main_client, source} = session_for(uris.main)
      {sub_client, ^source} = session_for(uris.sub)

      assert main_client != sub_client
      assert_pipeline_notified(pipeline, :source, {:stream_connected, :main, _tracks})
      assert_pipeline_notified(pipeline, :source, {:stream_connected, :sub, _tracks})

      keyframe(source, main_client, 0)
      keyframe(source, sub_client, 90_000)

      assert_sink_buffer(pipeline, :main, %Buffer{pts: 0})
      assert_sink_buffer(pipeline, :sub, %Buffer{pts: 1_000_000_000})
      refute_sink_buffer(pipeline, :main, %Buffer{}, 200)
    end

    test "a graceful stop ends both pads and reaps both clients" do
      {pipeline, uris} = start_dual([])
      {main_client, source} = session_for(uris.main)
      {sub_client, ^source} = session_for(uris.sub)

      reaped_main = Process.monitor(main_client)
      reaped_sub = Process.monitor(sub_client)

      keyframe(source, main_client, 0)
      keyframe(source, sub_client, 0)
      assert_sink_buffer(pipeline, :main, %Buffer{pts: 0})
      assert_sink_buffer(pipeline, :sub, %Buffer{pts: 0})

      Testing.Pipeline.notify_child(pipeline, :source, :eos)

      assert_end_of_stream(pipeline, :main)
      assert_end_of_stream(pipeline, :sub)
      assert_receive {:DOWN, ^reaped_main, :process, _pid, _reason}, 5_000
      assert_receive {:DOWN, ^reaped_sub, :process, _pid, _reason}, 5_000
    end

    test "a graceful stop cancels the pending retry of each role" do
      refusing = [connect: fn _attempt -> {:error, :refused} end]

      {pipeline, uris} =
        start_dual(main: refusing, sub: refusing, backoff_min_ms: 500, backoff_max_ms: 500)

      {_main_client, _source} = session_for(uris.main)
      {_sub_client, _source} = session_for(uris.sub)
      assert_pipeline_notified(pipeline, :source, {:stream_backoff, :main, :refused})
      assert_pipeline_notified(pipeline, :source, {:stream_backoff, :sub, :refused})

      # Both timers are pending here, and `stop_timer` on a role that has none
      # raises — a stop that forgot one role would crash the element rather
      # than merely leak a retry.
      Testing.Pipeline.notify_child(pipeline, :source, :eos)

      refute_session(uris.main, 500)
      refute_session(uris.sub, 500)
    end
  end

  describe "role independence" do
    test "a sub death closes the sub pad only, and main flows through its backoff" do
      {pipeline, uris} = start_dual(backoff_min_ms: 400, backoff_max_ms: 400)
      {main_client, source} = session_for(uris.main)
      {sub_client, ^source} = session_for(uris.sub)

      keyframe(source, main_client, 0)
      keyframe(source, sub_client, 0)
      assert_sink_buffer(pipeline, :main, %Buffer{pts: 0})
      assert_sink_buffer(pipeline, :sub, %Buffer{pts: 0})

      send(source, {:rtsp, sub_client, :session_closed})

      assert_sink_event(pipeline, :sub, %StreamClosed{})
      assert_pipeline_notified(pipeline, :source, {:stream_lost, :sub})

      # Main's session is untouched: no closure downstream, no lost/connected
      # notification, and its buffers keep landing while the sub is down.
      send(source, {:rtsp, main_client, {"video", {[@non_idr], 90_000, false, 2}}})
      assert_sink_buffer(pipeline, :main, %Buffer{pts: 1_000_000_000})
      refute_sink_event(pipeline, :main, %StreamClosed{}, 100)
      refute_pipeline_notified(pipeline, :source, {:stream_lost, :main}, 0)

      {sub_client2, ^source} = session_for(uris.sub)
      assert sub_client2 != sub_client
      refute_session(uris.main, 0)
    end

    test "a main death closes the main pad only, and the sub flows through its backoff" do
      {pipeline, uris} = start_dual(backoff_min_ms: 400, backoff_max_ms: 400)
      {main_client, source} = session_for(uris.main)
      {sub_client, ^source} = session_for(uris.sub)

      keyframe(source, main_client, 0)
      keyframe(source, sub_client, 0)
      assert_sink_buffer(pipeline, :main, %Buffer{pts: 0})
      assert_sink_buffer(pipeline, :sub, %Buffer{pts: 0})

      send(source, {:rtsp, main_client, :session_closed})

      assert_sink_event(pipeline, :main, %StreamClosed{})
      assert_pipeline_notified(pipeline, :source, {:stream_lost, :main})

      send(source, {:rtsp, sub_client, {"video", {[@non_idr], 90_000, false, 2}}})
      assert_sink_buffer(pipeline, :sub, %Buffer{pts: 1_000_000_000})
      refute_sink_event(pipeline, :sub, %StreamClosed{}, 100)
      refute_pipeline_notified(pipeline, :source, {:stream_lost, :sub}, 0)

      {main_client2, ^source} = session_for(uris.main)
      assert main_client2 != main_client
      refute_session(uris.sub, 0)
    end

    test "each role climbs — and resets — its own backoff ladder" do
      {pipeline, uris} =
        start_dual(
          sub: [connect: fn _attempt -> {:error, :refused} end],
          backoff_min_ms: 50,
          backoff_max_ms: 100_000
        )

      {main_client, source} = session_for(uris.main)
      {_refused, ^source} = session_for(uris.sub)

      # Four sub refusals leave the sub's next delay at 400-1200 ms.
      for _retry <- 1..3, do: session_for(uris.sub)

      send(source, {:rtsp, main_client, :session_closed})
      lost_at = System.monotonic_time(:millisecond)
      {main_client2, ^source} = session_for(uris.main, 1_000)

      # Main never failed, so its own ladder is still at the 50 ms minimum —
      # 75 ms at the top of the jitter, against the sub's 400 ms floor.
      assert System.monotonic_time(:millisecond) - lost_at < 300

      # Media on main resets main's ladder; the sub's climb must survive it.
      keyframe(source, main_client2, 0)
      assert_sink_buffer(pipeline, :main, %Buffer{pts: 0})

      session_for(uris.sub, 3_000)
      retried_at = System.monotonic_time(:millisecond)
      session_for(uris.sub, 5_000)
      assert System.monotonic_time(:millisecond) - retried_at >= 300
    end

    test "a sub that never comes back retries forever and is never rewired to main" do
      {pipeline, uris} =
        start_dual(
          sub: [connect: fn _attempt -> {:error, :refused} end],
          backoff_min_ms: 20,
          backoff_max_ms: 40
        )

      {main_client, source} = session_for(uris.main)
      for _retry <- 1..6, do: session_for(uris.sub)
      assert_pipeline_notified(pipeline, :source, {:stream_backoff, :sub, :refused})

      # Nothing in the element falls back: the sub pad stays silent, and main
      # is neither re-opened nor duplicated to feed it.
      keyframe(source, main_client, 0)
      assert_sink_buffer(pipeline, :main, %Buffer{pts: 0})
      refute_sink_buffer(pipeline, :sub, %Buffer{}, 200)
      refute_session(uris.main, 0)
    end
  end

  describe "sub-only" do
    test "connects the sub role alone, leaving the main pad unused" do
      sub_uri = uri()
      MockRTSP.setup(sub_uri, [])

      source = %Source{
        substream_uri: sub_uri,
        rtsp_module: MockRTSP,
        backoff_min_ms: 50,
        backoff_max_ms: 200
      }

      pipeline =
        Testing.Pipeline.start_link_supervised!(
          spec:
            child(:source, source)
            |> via_out(Pad.ref(:output, :sub))
            |> child(:sub, Testing.Sink)
        )

      {client, element} = session_for(sub_uri)
      assert_pipeline_notified(pipeline, :source, {:stream_connected, :sub, _tracks})
      refute_receive {:rtsp_started, _uri, _client, _opts}, 200

      keyframe(element, client, 0)
      assert_sink_buffer(pipeline, :sub, %Buffer{pts: 0})
    end

    test "neither uri is refused rather than run as a silent element" do
      assert_raise ArgumentError, ~r/stream_uri/, fn ->
        Source.handle_init(%{}, %Source{rtsp_module: MockRTSP})
      end
    end
  end
end
