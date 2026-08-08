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
    %Config{data_dir: "tmp/ffmpeg_port_test", udp_base_port: 19_000, stall_seconds: 1}
  end

  defp start_pipeline(id, command, opts) do
    start_supervised!({RingBuffer, camera_id: id, pre_window_seconds: 60})

    start_supervised!(
      {FFmpegPort,
       [
         camera: camera(id),
         config: config(),
         index: 0,
         command: command,
         backoff_min_ms: 50,
         backoff_max_ms: 200,
         watchdog_interval_ms: 100
       ] ++ opts}
    )
  end

  describe "build_argv/3" do
    test "rtsp input gets transport + timeout flags, three outputs" do
      argv = FFmpegPort.build_argv(camera("c"), {5001, 5002}, "-timeout")

      assert ["ffmpeg", "-nostdin" | _] = argv
      assert "-rtsp_transport" in argv
      assert "-timeout" in argv
      assert "pipe:1" in argv
      assert "rtp://127.0.0.1:5001" in argv
      assert "rtp://127.0.0.1:5002" in argv
      assert Enum.count(argv, &(&1 == "copy")) == 3
      # in-band SPS/PPS for both RTP outputs, never for the mp4 output
      assert Enum.count(argv, &(&1 == "h264_mp4toannexb")) == 2

      assert Enum.find_index(argv, &(&1 == "h264_mp4toannexb")) >
               Enum.find_index(argv, &(&1 == "pipe:1"))
    end

    test "stimeout fallback flag is used verbatim" do
      argv = FFmpegPort.build_argv(camera("c"), {5001, 5002}, "-stimeout")
      assert "-stimeout" in argv
      refute "-timeout" in argv
    end

    test "non-rtsp input loops in realtime instead" do
      cam = %Camera{id: "c", rtsp_url: "file:///tmp/x.mp4"}
      argv = FFmpegPort.build_argv(cam, {5001, 5002}, "-timeout")
      assert "-stream_loop" in argv
      refute "-rtsp_transport" in argv
    end

    test "http live input gets reconnect flags, no looping" do
      cam = %Camera{id: "c", rtsp_url: "http://cam/flv?stream=ch0"}
      argv = FFmpegPort.build_argv(cam, {5001, 5002}, "-timeout")
      assert "-reconnect" in argv
      refute "-stream_loop" in argv
      refute "-rtsp_transport" in argv
    end

    test "extra_ffmpeg_args are spliced before -i" do
      cam = %Camera{camera("c") | extra_ffmpeg_args: ["-analyzeduration", "5M"]}
      argv = FFmpegPort.build_argv(cam, {5001, 5002}, "-timeout")

      assert Enum.find_index(argv, &(&1 == "-analyzeduration")) <
               Enum.find_index(argv, &(&1 == "-i"))
    end

    test "shell_command escapes and redirects stderr" do
      cmd = FFmpegPort.shell_command(["ffmpeg", "-i", "rtsp://u:p w@h/s"], "/log/f f.log")
      assert cmd =~ "exec 'ffmpeg' '-i' 'rtsp://u:p w@h/s' 2>> '/log/f f.log'"
    end
  end

  describe "build_membrane_argv/3" do
    test "two outputs: mpegts on stdout + plugin rtp, hub output gone" do
      argv = FFmpegPort.build_membrane_argv(camera("c"), 5001, "-timeout")

      assert "-rtsp_transport" in argv
      assert "mpegts" in argv
      assert "pipe:1" in argv
      assert "rtp://127.0.0.1:5001" in argv
      assert Enum.count(argv, &String.starts_with?(&1, "rtp://")) == 1
      assert Enum.count(argv, &(&1 == "copy")) == 2
      # in-band SPS/PPS for the one remaining RTP output
      assert Enum.count(argv, &(&1 == "h264_mp4toannexb")) == 1
      refute "mp4" in argv
    end
  end

  describe "membrane mode lifecycle" do
    defmodule StubPipeline do
      # Stands in for Cairn.Pipeline.Camera: plays both roles of the
      # handshake (announces itself as the bridge source) and relays what it
      # receives to the test, so FFmpegPort's session wiring is observable
      # without media.
      use Membrane.Pipeline

      @impl true
      def handle_init(_ctx, opts) do
        owner = Keyword.fetch!(opts, :owner)
        test_pid = :persistent_term.get({:membrane_stub, Keyword.fetch!(opts, :camera_id)})
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

      cam = %Camera{camera(id) | pipeline: :membrane}

      start_supervised!(
        {FFmpegPort,
         [
           camera: cam,
           config: config(),
           index: 0,
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
      assert opts[:camera_id] == id
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

  describe "lifecycle with fake ffmpeg" do
    test "streams fixture into the ring and respawns after exit" do
      id = "ff_#{System.unique_integer([:positive])}"
      status_pid = self()

      start_pipeline(id, "#{@fake} #{@fixture} 0.05 42",
        status_fun: fn cam_id, status -> send(status_pid, {:status, cam_id, status}) end
      )

      assert_receive {:status, ^id, :connecting}, 2_000
      assert_receive {:status, ^id, :running}, 2_000

      {:ok, %{init: init, fragments: frags}} = wait_for_fragments(id, 3)
      assert is_binary(init)
      assert length(frags) >= 3

      # fake exits with 42 -> backoff -> respawn -> connecting/running again
      assert_receive {:status, ^id, :backoff}, 2_000
      assert_receive {:status, ^id, :connecting}, 2_000
      assert_receive {:status, ^id, :running}, 2_000
    end

    test "watchdog bounces a silently stalled process" do
      id = "ff_#{System.unique_integer([:positive])}"
      status_pid = self()

      # cats fixture then sleeps far longer than stall_seconds (1s)
      start_pipeline(id, "#{@fake} #{@fixture} 30 0",
        status_fun: fn cam_id, status -> send(status_pid, {:status, cam_id, status}) end
      )

      assert_receive {:status, ^id, :running}, 2_000
      assert_receive {:status, ^id, :stalled}, 5_000
      assert_receive {:status, ^id, :backoff}, 2_000
      assert_receive {:status, ^id, :connecting}, 2_000
    end
  end

  describe "stream epochs" do
    test "every spawn mints a new epoch and tags its init segment with it" do
      id = "ff_#{System.unique_integer([:positive])}"
      StreamEpochs.subscribe()
      Phoenix.PubSub.subscribe(Cairn.PubSub, RingBuffer.topic(id))

      # fake exits with 42 after streaming -> backoff -> second spawn
      start_pipeline(id, "#{@fake} #{@fixture} 0.05 42", [])

      # each half of this is separately covered (minting here, propagation in
      # RingBufferTest); only asserting both together pins that the port hands
      # the ring the epoch of the spawn that produced the init segment
      assert_receive {:stream_epoch, ^id, first, :started}, 2_000
      assert_receive {:init_segment, %{camera_id: ^id, epoch: ^first}}, 3_000

      assert_receive {:stream_epoch, ^id, second, :source_lost}, 5_000
      assert_receive {:init_segment, %{camera_id: ^id, epoch: ^second}}, 5_000
      assert first != second

      assert {:ok, current} = StreamEpochs.current(id)
      assert current != first
    end

    test "a stall bounce mints its epoch with the :stall_bounce reason" do
      id = "ff_#{System.unique_integer([:positive])}"
      StreamEpochs.subscribe()

      # cats fixture then sleeps far longer than stall_seconds (1s)
      start_pipeline(id, "#{@fake} #{@fixture} 30 0", [])

      assert_receive {:stream_epoch, ^id, _first, :started}, 2_000
      assert_receive {:stream_epoch, ^id, _second, :stall_bounce}, 5_000
    end

    test "stopping the camera announces the end of the stream" do
      id = "ff_#{System.unique_integer([:positive])}"
      StreamEpochs.subscribe()

      pid = start_pipeline(id, "#{@fake} #{@fixture} 30 0", [])
      assert_receive {:stream_epoch, ^id, _epoch, :started}, 2_000

      ref = Process.monitor(pid)
      stop_supervised!(FFmpegPort)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      assert_receive {:stream_epoch, ^id, _stopped, :camera_stopped}
    end
  end

  defp wait_for_fragments(id, min_count, deadline_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait(id, min_count, deadline)
  end

  defp do_wait(id, min_count, deadline) do
    {:ok, %{fragments: frags} = result} = RingBuffer.fetch_recent(id, 100)

    cond do
      length(frags) >= min_count ->
        {:ok, result}

      System.monotonic_time(:millisecond) > deadline ->
        flunk("only #{length(frags)} fragments buffered for #{id}, wanted #{min_count}")

      true ->
        Process.sleep(50)
        do_wait(id, min_count, deadline)
    end
  end
end
