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
    test "every spawn mints a new epoch" do
      id = "ff_#{System.unique_integer([:positive])}"
      StreamEpochs.subscribe()

      # fake exits with 42 after streaming -> backoff -> second spawn
      start_pipeline(id, "#{@fake} #{@fixture} 0.05 42", [])

      assert_receive {:stream_epoch, ^id, first, :started}, 2_000
      assert_receive {:stream_epoch, ^id, second, :source_lost}, 5_000
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
        {:ok, result}

      true ->
        Process.sleep(50)
        do_wait(id, min_count, deadline)
    end
  end
end
