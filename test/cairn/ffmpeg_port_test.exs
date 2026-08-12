defmodule Cairn.FFmpegPortTest do
  use ExUnit.Case, async: false

  alias Cairn.Config
  alias Cairn.Config.Camera
  alias Cairn.FFmpegPort
  alias Cairn.RingBuffer
  alias Cairn.StreamEpochs

  @fixture Path.absname("test/support/fixtures/media/testsrc.fmp4")
  @fake Path.absname("test/support/fake_ffmpeg.sh")

  defp camera(id), do: %Camera{id: id, rtsp_url: "rtsp://127.0.0.1:554/x"}

  defp config do
    %Config{data_dir: "tmp/ffmpeg_port_test", stall_seconds: 1}
  end

  describe "build_argv/2" do
    test "rtsp input gets transport + timeout flags, one mpegts output" do
      argv = FFmpegPort.build_argv(camera("c"), "-timeout")

      assert ["ffmpeg", "-nostdin" | _] = argv
      assert "-rtsp_transport" in argv
      assert "-timeout" in argv
      assert "mpegts" in argv
      assert "pipe:1" in argv
      # both RTP consumers are in-process, so ffmpeg emits one output and
      # the camera binds no UDP port at all
      assert Enum.count(argv, &(&1 == "-map")) == 1
      assert Enum.count(argv, &(&1 == "copy")) == 1
      refute Enum.any?(argv, &String.starts_with?(&1, "rtp://"))
      refute "rtp" in argv
      # the in-band SPS/PPS filter existed only for RTP outputs
      refute "h264_mp4toannexb" in argv
      refute "mp4" in argv
    end

    test "stimeout fallback flag is used verbatim" do
      argv = FFmpegPort.build_argv(camera("c"), "-stimeout")
      assert "-stimeout" in argv
      refute "-timeout" in argv
    end

    test "non-rtsp input loops in realtime instead" do
      cam = %Camera{id: "c", rtsp_url: "file:///tmp/x.mp4"}
      argv = FFmpegPort.build_argv(cam, "-timeout")
      assert "-stream_loop" in argv
      refute "-rtsp_transport" in argv
    end

    test "http live input gets reconnect flags, no looping" do
      cam = %Camera{id: "c", rtsp_url: "http://cam/flv?stream=ch0"}
      argv = FFmpegPort.build_argv(cam, "-timeout")
      assert "-reconnect" in argv
      refute "-stream_loop" in argv
      refute "-rtsp_transport" in argv
    end

    test "extra_ffmpeg_args are spliced before -i" do
      cam = %Camera{camera("c") | extra_ffmpeg_args: ["-analyzeduration", "5M"]}
      argv = FFmpegPort.build_argv(cam, "-timeout")

      assert Enum.find_index(argv, &(&1 == "-analyzeduration")) <
               Enum.find_index(argv, &(&1 == "-i"))
    end

    test "shell_command escapes and redirects stderr" do
      cmd = FFmpegPort.shell_command(["ffmpeg", "-i", "rtsp://u:p w@h/s"], "/log/f f.log")
      assert cmd =~ "exec 'ffmpeg' '-i' 'rtsp://u:p w@h/s' 2>> '/log/f f.log'"
    end
  end

  describe "session lifecycle" do
    defmodule StubPipeline do
      # Stands in for Cairn.Pipeline.Camera: plays both roles of the
      # handshake (announces itself as the bridge source) and relays what it
      # receives to the test, so FFmpegPort's session wiring is observable
      # without media.
      use Membrane.Pipeline

      @impl true
      def handle_init(_ctx, opts) do
        owner = Keyword.fetch!(opts, :owner)
        test_pid = :persistent_term.get({:membrane_stub, Keyword.fetch!(opts, :camera).id})
        send(owner, {:bridge_source_ready, Keyword.fetch!(opts, :epoch), self()})
        send(test_pid, {:pipeline_started, self(), opts})
        {[], %{test_pid: test_pid}}
      end

      @impl true
      def handle_info({:ts_data, data}, _ctx, state) do
        send(state.test_pid, {:ts, data})
        {[], state}
      end

      def handle_info(msg, _ctx, state) do
        send(state.test_pid, {:pipeline_msg, msg})
        {[], state}
      end
    end

    defmodule FailingPipeline do
      # A pipeline_module that never reaches a running state: its handle_init
      # raises, so FFmpegPort's start-failure path fires (either start/3 returns
      # {:error, _} or it returns ok and the monitor sees the crash).
      use Membrane.Pipeline

      @impl true
      def handle_init(_ctx, _opts), do: raise("pipeline refused to start")
    end

    defp start_membrane(id, opts, module \\ StubPipeline) do
      :persistent_term.put({:membrane_stub, id}, self())
      on_exit(fn -> :persistent_term.erase({:membrane_stub, id}) end)

      start_supervised!({RingBuffer, camera_id: id, pre_window_seconds: 60})

      start_supervised!(
        {FFmpegPort,
         [
           camera: camera(id),
           config: config(),
           backoff_min_ms: 50,
           backoff_max_ms: 200,
           watchdog_interval_ms: 100,
           pipeline_module: module
         ] ++ opts}
      )
    end

    test "spawns a pipeline per session and forwards stdout bytes to the source" do
      id = "mm_#{System.unique_integer([:positive])}"

      start_membrane(id, command: "#{@fake} #{@fixture} 0.05 42")

      assert_receive {:pipeline_started, _pid, opts}, 2_000
      assert opts[:camera].id == id
      assert is_binary(opts[:epoch])

      # fake ffmpeg's stdout reaches the announced source
      assert_receive {:ts, data}, 2_000
      assert is_binary(data)

      # ffmpeg's exit flushes the session (eos) before teardown, then
      # backoff brings a fresh pipeline with a fresh epoch
      assert_receive {:pipeline_msg, :ts_eos}, 2_000
      assert_receive {:pipeline_started, _pid2, opts2}, 2_000
      assert opts2[:epoch] != opts[:epoch]
    end

    test "a refresh reaches the running pipeline's detect branch, not ffmpeg" do
      id = "mr_#{System.unique_integer([:positive])}"
      port = start_membrane(id, command: "#{@fake} #{@fixture} 600 0")

      assert_receive {:pipeline_started, pipeline, _opts}, 2_000
      cam = %Camera{camera(id) | record: %{"person" => %{min_score: 0.9}}}

      # a tier edit is refresh-only: the detect branch has to be told, and the
      # session it is part of has to survive being told
      :ok = FFmpegPort.refresh(port, cam, config())

      assert_receive {:pipeline_msg, {:policy, ^cam, policy}}, 2_000
      assert policy.record == cam.record
      assert :sys.get_state(port).pipeline == pipeline
    end

    test ":running rides ring broadcasts, gated on this session's epoch" do
      id = "mg_#{System.unique_integer([:positive])}"
      status_pid = self()

      start_membrane(id, [
        {:command, "#{@fake} #{@fixture} 600 0"},
        {:status_fun, fn cam_id, status -> send(status_pid, {:status, cam_id, status}) end}
      ])

      assert_receive {:status, ^id, :connecting}, 2_000
      assert_receive {:pipeline_started, _pid, opts}, 2_000
      epoch = opts[:epoch]

      topic = RingBuffer.topic(id)

      # a stale session's init + fragment must not mark the new one running
      Phoenix.PubSub.broadcast(Cairn.PubSub, topic, {:init_segment, %{epoch: "stale"}})
      Phoenix.PubSub.broadcast(Cairn.PubSub, topic, {:fragment, :whatever})
      refute_receive {:status, ^id, :running}, 200

      Phoenix.PubSub.broadcast(Cairn.PubSub, topic, {:init_segment, %{epoch: epoch}})
      Phoenix.PubSub.broadcast(Cairn.PubSub, topic, {:fragment, :whatever})
      assert_receive {:status, ^id, :running}, 2_000
    end

    test "a dying pipeline ends the session with backoff" do
      id = "md_#{System.unique_integer([:positive])}"
      status_pid = self()

      start_membrane(id, [
        {:command, "#{@fake} #{@fixture} 600 0"},
        {:status_fun, fn cam_id, status -> send(status_pid, {:status, cam_id, status}) end}
      ])

      assert_receive {:pipeline_started, pid, _opts}, 2_000
      Process.exit(pid, :kill)

      assert_receive {:status, ^id, :backoff}, 2_000
      assert_receive {:pipeline_started, pid2, _opts2}, 2_000
      assert pid2 != pid
    end

    test "a pipeline that fails to start drops the camera into backoff, then retries" do
      id = "mf_#{System.unique_integer([:positive])}"
      status_pid = self()

      # The crash reports from the failing pipeline are expected noise here.
      ExUnit.CaptureLog.capture_log(fn ->
        start_membrane(
          id,
          [
            {:command, "#{@fake} #{@fixture} 600 0"},
            {:status_fun, fn cam_id, status -> send(status_pid, {:status, cam_id, status}) end}
          ],
          FailingPipeline
        )

        # Whichever internal path fires (start/3 {:error, _} or ok-then-DOWN),
        # the observable is the same: the session ends in backoff and the next
        # spawn re-enters :connecting.
        assert_receive {:status, ^id, :connecting}, 2_000
        assert_receive {:status, ^id, :backoff}, 2_000
        assert_receive {:status, ^id, :connecting}, 2_000
      end)
    end
  end

  describe "watchdog" do
    test "bounces a silently stalled session" do
      id = "ff_#{System.unique_integer([:positive])}"
      status_pid = self()
      StreamEpochs.subscribe()

      start_membrane(id, [
        {:command, "#{@fake} #{@fixture} 600 0"},
        {:status_fun, fn cam_id, status -> send(status_pid, {:status, cam_id, status}) end}
      ])

      assert_receive {:pipeline_started, _pid, opts}, 2_000
      epoch = opts[:epoch]

      # The sink's feed, stood in for by hand: one init + one fragment mark
      # the session running and start the stall clock. Nothing follows, and
      # stall_seconds is 1.
      RingBuffer.put_init(id, <<1>>, "avc1.64001f", 90_000, epoch)
      RingBuffer.put_fragment(id, %Cairn.Fragment{camera_id: id, seq: 0, pts: 0, data: <<1>>})

      assert_receive {:status, ^id, :running}, 2_000
      assert_receive {:status, ^id, :stalled}, 5_000
      assert_receive {:status, ^id, :backoff}, 2_000
      assert_receive {:stream_epoch, ^id, _second, :stall_bounce}, 5_000
    end
  end

  describe "stream epochs" do
    test "every spawn mints a new epoch, respawn reason :source_lost" do
      id = "ff_#{System.unique_integer([:positive])}"
      StreamEpochs.subscribe()

      # fake exits with 42 after streaming -> flush -> backoff -> second spawn
      start_membrane(id, command: "#{@fake} #{@fixture} 0.05 42")

      assert_receive {:stream_epoch, ^id, first, :started}, 2_000
      assert_receive {:stream_epoch, ^id, second, :source_lost}, 5_000
      assert first != second

      assert {:ok, current} = StreamEpochs.current(id)
      assert current != first
    end

    test "stopping the camera announces the end of the stream" do
      id = "ff_#{System.unique_integer([:positive])}"
      StreamEpochs.subscribe()

      pid = start_membrane(id, command: "#{@fake} #{@fixture} 600 0")
      assert_receive {:stream_epoch, ^id, _epoch, :started}, 2_000

      ref = Process.monitor(pid)
      stop_supervised!(FFmpegPort)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      assert_receive {:stream_epoch, ^id, _stopped, :camera_stopped}
    end
  end

  describe "rtsp ingest lifecycle" do
    defmodule RtspStubPipeline do
      # Stands in for Cairn.Pipeline.Camera on the rtsp path: announces
      # itself as the RtspSource and relays what it receives to the test.
      use Membrane.Pipeline

      @impl true
      def handle_init(_ctx, opts) do
        owner = Keyword.fetch!(opts, :owner)
        test_pid = :persistent_term.get({:membrane_stub, Keyword.fetch!(opts, :camera).id})
        send(owner, {:rtsp_source_ready, Keyword.fetch!(opts, :epoch), self()})
        send(test_pid, {:pipeline_started, self(), opts})
        {[], %{test_pid: test_pid}}
      end

      @impl true
      def handle_info(msg, _ctx, state) do
        send(state.test_pid, {:pipeline_msg, msg})
        {[], state}
      end
    end

    defmodule SilentPipeline do
      # Starts but never announces a source, so the port's pending buffer is
      # observable.
      use Membrane.Pipeline

      @impl true
      def handle_init(_ctx, opts) do
        test_pid = :persistent_term.get({:membrane_stub, Keyword.fetch!(opts, :camera).id})
        send(test_pid, {:pipeline_started, self(), opts})
        {[], %{}}
      end
    end

    defp start_rtsp(id, opts \\ []) do
      :persistent_term.put({:membrane_stub, id}, self())
      uri = "rtsp://127.0.0.1:554/#{id}"
      Cairn.RTSPStub.control(uri, Map.new(Keyword.get(opts, :control, test: self())))

      on_exit(fn ->
        :persistent_term.erase({:membrane_stub, id})
        :persistent_term.erase({Cairn.RTSPStub, uri})
      end)

      start_supervised!({RingBuffer, camera_id: id, pre_window_seconds: 60})

      cam = %Camera{camera(id) | rtsp_url: uri, ingest: :rtsp}

      # Prepended so a test's override wins: FFmpegPort reads its opts with
      # Keyword.get, which takes the first occurrence.
      start_supervised!(
        {FFmpegPort,
         Keyword.get(opts, :port_opts, []) ++
           [
             camera: cam,
             config: config(),
             backoff_min_ms: 50,
             backoff_max_ms: 200,
             watchdog_interval_ms: 100,
             pipeline_module: Keyword.get(opts, :pipeline, RtspStubPipeline),
             rtsp_module: Cairn.RTSPStub
           ]}
      )
    end

    test "starts the client and a pipeline; samples reach the source with ns pts" do
      id = "rt_#{System.unique_integer([:positive])}"
      port = start_rtsp(id)

      assert_receive {:rtsp_started, client, rtsp_opts}, 2_000
      assert rtsp_opts[:transport] == :tcp
      # Video only: audio would be SETUP, received and depayloaded just to
      # be discarded — and a broken audio track must not refuse the session.
      assert rtsp_opts[:allowed_media_types] == [:video]
      assert_receive {:pipeline_started, _pipeline, opts}, 2_000
      assert opts[:ingest] == :rtsp
      assert is_binary(opts[:epoch])

      # One second of RTP clock becomes one second of Membrane time; the
      # library's bare-NAL list gets its Annex-B framing back (one 4-byte
      # start code per NAL — the decoder strips them at RTP ingest); and
      # only the negotiated video path's samples cross.
      send(
        port,
        {:rtsp, client, {"video", {[<<0x67, 1>>, <<0x68>>, <<0x65, 9>>], 90_000, true, 123}}}
      )

      send(port, {:rtsp, client, {"audio", {[<<0xFF>>], 48_000, true, 123}}})

      framed = <<0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 0, 0, 0, 1, 0x65, 9>>
      assert_receive {:pipeline_msg, {:rtsp_sample, ^framed, 1_000_000_000}}, 2_000
      refute_receive {:pipeline_msg, {:rtsp_sample, _, _}}, 100

      # Batched delivery: a list of samples fans out in order.
      send(
        port,
        {:rtsp, client, {"video", [{[<<1>>], 0, false, 124}, {[<<2>>], 9_000, false, 125}]}}
      )

      assert_receive {:pipeline_msg, {:rtsp_sample, <<0, 0, 0, 1, 1>>, 0}}, 2_000
      assert_receive {:pipeline_msg, {:rtsp_sample, <<0, 0, 0, 1, 2>>, 100_000_000}}, 2_000
    end

    test "session_closed flushes the tail, respawns fresh, and reaps the old client" do
      id = "rc_#{System.unique_integer([:positive])}"
      port = start_rtsp(id)

      assert_receive {:rtsp_started, client, _}, 2_000
      assert_receive {:pipeline_started, _pipeline, opts}, 2_000

      # The library's stop/1 leaves the client process alive by design; the
      # port must end it or leak one process per session.
      reaped = Process.monitor(client)

      send(port, {:rtsp, client, :session_closed})

      # The tail-flush contract: eos reaches the source before teardown.
      assert_receive {:pipeline_msg, :rtsp_eos}, 2_000

      # ...and the respawn is a whole new session: new client, new epoch.
      assert_receive {:rtsp_started, client2, _}, 2_000
      assert_receive {:pipeline_started, _pipeline2, opts2}, 2_000
      assert client2 != client
      assert opts2[:epoch] != opts[:epoch]
      assert_receive {:DOWN, ^reaped, :process, _pid, _reason}, 5_000
    end

    test "a crashed client gets the same tail flush and recovery as a closed session" do
      id = "rk_#{System.unique_integer([:positive])}"
      _port = start_rtsp(id)

      assert_receive {:rtsp_started, client, _}, 2_000
      assert_receive {:pipeline_started, _pipeline, opts}, 2_000

      Process.exit(client, :kill)

      # Everything the client delivered is ordered ahead of the :DOWN, so
      # the CMAF tail is as recoverable here as on a graceful close.
      assert_receive {:pipeline_msg, :rtsp_eos}, 2_000

      assert_receive {:rtsp_started, client2, _}, 2_000
      assert_receive {:pipeline_started, _pipeline2, opts2}, 2_000
      assert client2 != client
      assert opts2[:epoch] != opts[:epoch]
    end

    test "a connect that exits the caller (slow camera) is a backoff, not a crash" do
      id = "rt_#{System.unique_integer([:positive])}"

      start_rtsp(id,
        control: [test: self(), connect: :exit],
        port_opts: [backoff_min_ms: 800]
      )

      # The first client's connect exits the calling port (as a real call
      # timeout would); the port survives it as a refusal.
      assert_receive {:rtsp_started, _timed_out, _}, 2_000
      refute_receive {:pipeline_started, _, _}, 100

      assert_receive {:rtsp_started, _client, _}, 3_000
      assert_receive {:pipeline_started, _pipeline, _opts}, 2_000
    end

    test "a video track without rtp metadata is refused by its own name" do
      id = "rm_#{System.unique_integer([:positive])}"

      tracks = [%{control_path: "video", type: :video, fmtp: nil, rtpmap: nil}]
      start_rtsp(id, control: [test: self(), tracks: tracks])

      assert_receive {:rtsp_started, _client, _}, 2_000
      refute_receive {:pipeline_started, _, _}, 300
      assert_receive {:rtsp_started, _client2, _}, 2_000
    end

    test "a refused start (bad host) is a value and a backoff, not a crash" do
      id = "rx_#{System.unique_integer([:positive])}"

      start_rtsp(id,
        control: [test: self(), start: {:error, :nxdomain}],
        port_opts: [backoff_min_ms: 800]
      )

      # The refusal happened before any client existed; the port survived it
      # (a MatchError here would restart the camera process and lose its
      # backoff state) and the retry recovers.
      assert_receive {:rtsp_start_refused, {:error, :nxdomain}}, 2_000
      refute_receive {:pipeline_started, _, _}, 100

      assert_receive {:rtsp_started, _client, _}, 3_000
      assert_receive {:pipeline_started, _pipeline, _opts}, 2_000
    end

    test "a refused connect backs off and the retry recovers" do
      id = "rr_#{System.unique_integer([:positive])}"

      # Backoff floor with real margin over the refute window: the jittered
      # delay is backoff_ms * (0.5 + rand), so 800 ms yields at least 400 ms
      # before the retry's own (legitimate) pipeline can appear.
      start_rtsp(id,
        control: [test: self(), connect: {:error, :econnrefused}],
        port_opts: [backoff_min_ms: 800]
      )

      # First client is started, refused at connect, and no pipeline exists
      # for it; the stub consumes the refusal so the retry connects.
      assert_receive {:rtsp_started, _refused, _}, 2_000
      refute_receive {:pipeline_started, _, _}, 100

      assert_receive {:rtsp_started, _client, _}, 3_000
      assert_receive {:pipeline_started, _pipeline, _opts}, 2_000
    end

    test "a ready queued during backoff cannot become the next session's source" do
      id = "rb_#{System.unique_integer([:positive])}"
      port = start_rtsp(id, port_opts: [backoff_min_ms: 800])

      assert_receive {:rtsp_started, client, _}, 2_000
      assert_receive {:pipeline_started, _pipeline, opts}, 2_000

      send(port, {:rtsp, client, :session_closed})
      assert_receive {:pipeline_msg, :rtsp_eos}, 2_000

      # In the backoff window the epoch is still the dead session's — a ready
      # the dying pipeline queued matches it and must not survive into the
      # next spawn as a dead `source`.
      send(port, {:rtsp_source_ready, opts[:epoch], self()})

      assert_receive {:rtsp_started, client2, _}, 3_000
      assert_receive {:pipeline_started, _pipeline2, _opts2}, 2_000

      send(port, {:rtsp, client2, {"video", {[<<3>>], 0, true, 0}}})

      # The new session's pipeline gets the sample (pended or direct); the
      # impostor (us) never does.
      assert_receive {:pipeline_msg, {:rtsp_sample, <<0, 0, 0, 1, 3>>, 0}}, 2_000
      refute_received {:rtsp_sample, _, _}
    end

    test "a stale ready handshake cannot claim the live session's samples" do
      id = "rf_#{System.unique_integer([:positive])}"
      port = start_rtsp(id)

      assert_receive {:rtsp_started, client, _}, 2_000
      assert_receive {:pipeline_started, _pipeline, _opts}, 2_000

      # A source outliving a force-killed predecessor announces itself with
      # ITS session's epoch — never the live one's — and must be ignored.
      send(port, {:rtsp_source_ready, "01STALEEPOCH00000000000000", self()})
      send(port, {:rtsp, client, {"video", {[<<5>>], 0, true, 0}}})

      # The live pipeline keeps receiving; the impostor (us) never does.
      assert_receive {:pipeline_msg, {:rtsp_sample, <<0, 0, 0, 1, 5>>, 0}}, 2_000
      refute_received {:rtsp_sample, _, _}
    end

    @tag :capture_log
    test "samples ahead of the handshake are pended, and the flood is bounded" do
      id = "rp_#{System.unique_integer([:positive])}"
      # A pipeline that never announces a source: everything pends.
      port = start_rtsp(id, pipeline: __MODULE__.SilentPipeline)

      assert_receive {:rtsp_started, client, _}, 2_000
      assert_receive {:pipeline_started, _pipeline, _opts}, 2_000

      # Three 3 MB samples: the third crosses the 8 MB cap and is dropped —
      # visible in state rather than unbounded memory.
      big = :binary.copy(<<0>>, 3 * 1024 * 1024)

      for pts <- [0, 9_000, 18_000] do
        send(port, {:rtsp, client, {"video", {big, pts, false, 0}}})
      end

      state = :sys.get_state(port)
      assert state.pending_bytes <= 8 * 1024 * 1024
      assert length(state.pending) == 2
      assert state.dropped_bytes > 0
    end

    test "a camera advertising no H264 video track is refused, not decoded wrong" do
      id = "rh_#{System.unique_integer([:positive])}"

      tracks = [
        %{
          control_path: "video",
          type: :video,
          fmtp: nil,
          rtpmap: %{encoding: "H265", clock_rate: 90_000}
        }
      ]

      start_rtsp(id, control: [test: self(), tracks: tracks])

      assert_receive {:rtsp_started, _client, _}, 2_000
      # Refused every time: the camera cannot become a session.
      refute_receive {:pipeline_started, _, _}, 300
      # ...but the port keeps trying (backoff, not a crash).
      assert_receive {:rtsp_started, _client2, _}, 2_000
    end

    test "a stale session's messages are dropped, not misrouted" do
      id = "rs_#{System.unique_integer([:positive])}"
      port = start_rtsp(id)

      assert_receive {:rtsp_started, client, _}, 2_000
      assert_receive {:pipeline_started, _pipeline, _opts}, 2_000

      dead_client = spawn(fn -> :ok end)
      send(port, {:rtsp, dead_client, {"video", {[<<9>>], 0, true, 0}}})
      refute_receive {:pipeline_msg, {:rtsp_sample, _, _}}, 100

      # The live session is unaffected.
      send(port, {:rtsp, client, {"video", {[<<7>>], 0, true, 0}}})
      assert_receive {:pipeline_msg, {:rtsp_sample, <<0, 0, 0, 1, 7>>, 0}}, 2_000
    end
  end
end
