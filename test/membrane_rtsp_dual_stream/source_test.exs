defmodule Membrane.RTSPDualStream.SourceTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad, as: Pad

  alias Membrane.Buffer
  alias Membrane.RTSPDualStream.Event.StreamClosed
  alias Membrane.RTSPDualStream.Source
  alias Membrane.Testing

  defmodule MockRTSP do
    @moduledoc """
    Stand-in for the `rtsp` library's client. Mirrors the surface the source
    calls — `start/1`, `connect/1`, `play/1`, `stop/1` — as a real process,
    so monitors, `:DOWN` and the "stop/1 leaves the GenServer alive"
    contract all hold. Each started client announces itself to the test as
    `{:rtsp_started, client, opts}`; the test then *is* the camera and sends
    `{:rtsp, client, ...}` to `opts[:receiver]` exactly as the library does.

    `connect:` is a `(attempt_index -> :ok | {:error, reason} | :exit)`
    function, so a whole refusal-then-recovery ladder is one closure.
    """

    use GenServer

    def default_tracks do
      [
        %{
          control_path: "video",
          type: :video,
          fmtp: nil,
          rtpmap: %{encoding: "H264", clock_rate: 90_000}
        }
      ]
    end

    def setup(uri, opts) do
      control = %{
        test: self(),
        tracks: Keyword.get(opts, :tracks, default_tracks()),
        connect: Keyword.get(opts, :connect, fn _attempt -> :ok end),
        attempts: :counters.new(1, [])
      }

      :persistent_term.put({__MODULE__, uri}, control)
      ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase({__MODULE__, uri}) end)
    end

    def start(opts) do
      control = :persistent_term.get({__MODULE__, Keyword.fetch!(opts, :stream_uri)})
      GenServer.start(__MODULE__, {control, opts})
    end

    def connect(client), do: GenServer.call(client, :connect)
    def play(client), do: GenServer.call(client, :play)

    # Faithful to the library: `stop/1` cleans the session and replies but
    # deliberately leaves the GenServer alive. A stub that died here would
    # mask a client-process leak.
    def stop(client), do: GenServer.call(client, :stop)

    @impl true
    def init({control, opts}) do
      send(control.test, {:rtsp_started, self(), opts})
      {:ok, control}
    end

    @impl true
    def handle_call(:connect, _from, control) do
      attempt = :counters.get(control.attempts, 1)
      :counters.add(control.attempts, 1, 1)

      case control.connect.(attempt) do
        :ok ->
          {:reply, {:ok, control.tracks}, control}

        {:error, _reason} = refusal ->
          {:reply, refusal, control}

        # The library's connect/play are GenServer.calls, so a slow camera
        # EXITS the caller rather than returning an error — simulated by
        # stopping without a reply, no real timeout to wait out.
        :exit ->
          {:stop, {:shutdown, :mock_slow_connect}, control}
      end
    end

    def handle_call(:play, _from, control), do: {:reply, :ok, control}
    def handle_call(:stop, _from, control), do: {:reply, :ok, control}
  end

  # 1280x720 baseline SPS, verified against MediaCodecs.H264.NALU.SPS.
  @sps <<0x67, 0x42, 0x00, 0x1E, 0xF4, 0x02, 0x80, 0x2D, 0xC8>>
  @pps <<0x68, 0xCE, 0x3C, 0x80>>
  @idr <<0x65, 0x88, 0x84, 0x00>>
  @non_idr <<0x41, 0x9A, 0x00>>

  @keyframe_au [@sps, @pps, @idr]

  defp start_source(opts) do
    uri = "rtsp://127.0.0.1:554/cam#{System.unique_integer([:positive])}"
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

  # The element's own pid, learned the way the library learns it: from the
  # `receiver:` it was started with.
  defp session(timeout \\ 2_000) do
    assert_receive {:rtsp_started, client, opts}, timeout
    {client, opts[:receiver], opts}
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
      refute_receive {:rtsp_started, _client, _opts}, 100
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
      refute_receive {:rtsp_started, _client2, _opts}, 300
    end

    test "cancels a pending reconnect instead of stopping a timer that never ran" do
      pipeline = start_source(connect: fn _attempt -> {:error, :refused} end, backoff_min_ms: 500)
      {_client, _source, _opts} = session()

      assert_pipeline_notified(pipeline, :source, {:stream_backoff, :main, :refused})

      # A source that never emitted has no stream to end; the point is that
      # the pending retry timer is stopped rather than left to fire.
      Testing.Pipeline.notify_child(pipeline, :source, :eos)
      refute_receive {:rtsp_started, _client, _opts}, 800
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
end
