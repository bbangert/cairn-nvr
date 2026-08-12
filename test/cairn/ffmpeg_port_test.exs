defmodule Cairn.FFmpegPortTest do
  use ExUnit.Case, async: false

  alias Cairn.Config
  alias Cairn.Config.Camera
  alias Cairn.FFmpegPort

  @fixture Path.absname("test/support/fixtures/media/testsrc.fmp4")
  @fake Path.absname("test/support/fake_ffmpeg.sh")

  defmodule FakeSource do
    @moduledoc """
    Stands in for `Cairn.Pipeline.BridgeSource`: registers under
    `{camera_id, :bridge_source}` — the only thing the port resolves it by —
    and relays everything it is sent to the test.
    """
    use GenServer

    def start_link({camera_id, test}), do: GenServer.start_link(__MODULE__, {camera_id, test})

    @impl true
    def init({camera_id, test}) do
      {:ok, _pid} = Cairn.Registry.register(camera_id, :bridge_source)
      send(test, {:source_registered, self()})
      {:ok, test}
    end

    @impl true
    def handle_info(message, test) do
      send(test, {:source, message})
      {:noreply, test}
    end
  end

  defp camera(id), do: %Camera{id: id, rtsp_url: "rtsp://127.0.0.1:554/x"}

  defp config do
    %Config{data_dir: "tmp/ffmpeg_port_test", stall_seconds: 1}
  end

  defp uid(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp start_source(id) do
    start_supervised!({FakeSource, {id, self()}}, id: {:source, id})
    assert_receive {:source_registered, pid}, 2_000
    pid
  end

  # Prepended so a test's override wins: FFmpegPort reads its opts with
  # Keyword.get, which takes the first occurrence.
  defp start_port(id, opts) do
    start_supervised!(
      {FFmpegPort,
       opts ++
         [
           camera: camera(id),
           config: config(),
           backoff_min_ms: 50,
           backoff_max_ms: 200,
           resolve_interval_ms: 20,
           status_fun: fn _id, _status -> :ok end
         ]}
    )
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

  describe "the bridge source" do
    test "is resolved from the registry and fed ffmpeg's stdout" do
      id = uid("fw")
      start_source(id)
      start_port(id, command: "#{@fake} #{@fixture} 600 0")

      assert_receive {:source, {:ts_data, data}}, 5_000
      assert is_binary(data)
    end

    test "media that arrives before it exists is held, then flushed in order" do
      id = uid("fh")
      # The whole fixture is cat'ed at once and the fake then idles: nothing
      # more will arrive to carry a late resolution, so the port has to go
      # looking for the source itself.
      start_port(id, command: "#{@fake} #{@fixture} 600 0")

      # give ffmpeg time to deliver everything into the hold — comfortably
      # past several `resolve_interval_ms: 20` (start_port/2) retries with
      # nothing to resolve
      Process.sleep(300)
      start_source(id)

      assert_receive {:source, {:ts_data, first}}, 5_000
      assert match?(<<_::32, "ftyp", _::binary>>, first)
    end

    @tag :capture_log
    test "once resolved, media with nowhere to go is dropped rather than re-held" do
      id = uid("fd")
      source = start_source(id)
      start_port(id, command: "#{@fake} #{@fixture} 600 0")

      port = Cairn.Registry.whereis(id, :ffmpeg)
      assert_receive {:source, {:ts_data, _data}}, 5_000

      # A pipeline being rebuilt: its bytes are a lost session, not a backlog,
      # and holding them would splice two sessions across the cut.
      stop_supervised!({:source, id})
      refute Process.alive?(source)

      wait_until(fn -> :sys.get_state(port).source == nil end)
      state = :sys.get_state(port)
      assert state.resolved?
      assert state.pending == []
    end
  end

  describe "session signalling" do
    test "an ffmpeg exit closes the session in band, then respawns" do
      id = uid("fx")
      start_source(id)
      start_port(id, command: "#{@fake} #{@fixture} 0.05 42")

      assert_receive {:source, {:bridge_session_closed, :closed}}, 5_000
      # …and the respawn is a whole new ffmpeg feeding the same element
      assert_receive {:source, {:ts_data, _data}}, 5_000
    end

    test "bounce/1 cuts the session as :stall_bounce and respawns" do
      id = uid("fb")
      start_source(id)
      start_port(id, command: "#{@fake} #{@fixture} 600 0")

      port = Cairn.Registry.whereis(id, :ffmpeg)
      assert_receive {:source, {:ts_data, _data}}, 5_000
      assert FFmpegPort.running?(port)

      :ok = FFmpegPort.bounce(port)

      assert_receive {:source, {:bridge_session_closed, :stall_bounce}}, 5_000
      assert_receive {:source, {:ts_data, _data}}, 5_000
    end

    test "a bounce while already backing off does not put two ffmpegs on the camera" do
      id = uid("fbb")
      start_source(id)
      # 800 ms floor on the backoff, so the window is wide enough to bounce in
      start_port(id,
        command: "#{@fake} #{@fixture} 0.05 42",
        backoff_min_ms: 800,
        backoff_max_ms: 2_000
      )

      port = Cairn.Registry.whereis(id, :ffmpeg)
      assert_receive {:source, {:bridge_session_closed, :closed}}, 5_000
      refute FFmpegPort.running?(port)

      :ok = FFmpegPort.bounce(port)
      # the bounce is a no-op, so no second cut is announced
      refute_receive {:source, {:bridge_session_closed, _reason}}, 300

      # …and exactly one respawn follows, from the backoff already scheduled
      assert_receive {:source, {:ts_data, _data}}, 5_000
    end

    test "running?/1 answers false for a port that is gone" do
      refute FFmpegPort.running?(spawn(fn -> :ok end))
    end
  end

  describe "status" do
    test "reports its own connect/backoff, and never :running" do
      id = uid("fs")
      test = self()
      start_source(id)

      start_port(id,
        command: "#{@fake} #{@fixture} 0.05 42",
        status_fun: fn cam_id, status -> send(test, {:status, cam_id, status}) end
      )

      assert_receive {:status, ^id, :connecting}, 2_000
      assert_receive {:status, ^id, :backoff}, 5_000
      assert_receive {:status, ^id, :connecting}, 5_000

      # media flowing is the ring's answer and `Cairn.PipelineOwner` gives it;
      # a bridge that connects and never decodes must not read as healthy
      refute_received {:status, ^id, :running}
    end
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
