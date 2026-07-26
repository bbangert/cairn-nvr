defmodule Cairn.FFmpegPort do
  @moduledoc """
  Owns one camera's ffmpeg process as a Port.

  Spawns via `/bin/sh -c "exec ffmpeg ... 2>> {data_dir}/log/ffmpeg-{id}.log"`
  so stdout stays a clean fmp4 byte stream (stderr can neither be merged nor
  silently dropped) and Port signals reach the real ffmpeg thanks to `exec`.

  stdout is streamed through `Cairn.MP4.Demuxer`; init segments and
  fragments are cast to the camera's `Cairn.RingBuffer`.

  Reconnect policy lives *inside* this GenServer: on `:exit_status` it
  enters a jittered backoff (1s -> 30s) and respawns itself — a dead camera
  is a normal long-lived state and must not burn supervisor restart
  intensity. A periodic watchdog bounces ffmpeg when the ring has seen no
  fragment for `stall_seconds` (silent stall, e.g. a wedged TCP session).

  Status transitions (`:connecting | :running | :backoff | :stalled`) are
  reported through the `:status_fun` callback (wired to `Cairn.CameraStatus`).

  Every spawn mints a new stream epoch (`Cairn.StreamEpochs`) — one epoch is
  one continuous decode, so nothing (object ids, pts) carries across a
  respawn.
  """

  use GenServer

  require Logger

  alias Cairn.MP4.Demuxer

  @backoff_min_ms 1_000
  @backoff_max_ms 30_000

  defstruct camera: nil,
            config: nil,
            index: 0,
            port: nil,
            os_pid: nil,
            demuxer: nil,
            # :init so the first real transition (:connecting) is always emitted
            status: :init,
            backoff_ms: nil,
            opts: [],
            got_fragment: false,
            epoch: nil,
            # reason carried into the *next* spawn's epoch
            spawn_reason: :started

  def start_link(opts) do
    cam = Keyword.fetch!(opts, :camera)
    GenServer.start_link(__MODULE__, opts, name: Cairn.Registry.via(cam.id, :ffmpeg))
  end

  @doc """
  The RTSP socket-timeout flag for the installed ffmpeg: `-stimeout` was
  renamed `-timeout` in modern versions. Probed once and cached.
  """
  @spec timeout_flag() :: String.t()
  def timeout_flag do
    case :persistent_term.get({__MODULE__, :timeout_flag}, nil) do
      nil ->
        flag = probe_timeout_flag()
        :persistent_term.put({__MODULE__, :timeout_flag}, flag)
        flag

      flag ->
        flag
    end
  end

  defp probe_timeout_flag do
    {out, _status} =
      System.cmd("ffmpeg", ["-hide_banner", "-h", "demuxer=rtsp"], stderr_to_stdout: true)

    if out =~ ~r/^\s*-timeout\b/m, do: "-timeout", else: "-stimeout"
  rescue
    _ -> "-timeout"
  end

  @doc """
  Is the opt-in hardware encoder (`h264_v4l2m2m`) available? Probed once
  and cached. There is deliberately NO software (libx264) fallback.
  """
  @spec transcode_available?() :: boolean()
  def transcode_available? do
    case :persistent_term.get({__MODULE__, :v4l2m2m}, nil) do
      nil ->
        available = probe_encoder()
        :persistent_term.put({__MODULE__, :v4l2m2m}, available)
        available

      available ->
        available
    end
  end

  defp probe_encoder do
    {out, 0} = System.cmd("ffmpeg", ["-hide_banner", "-encoders"], stderr_to_stdout: true)
    String.contains?(out, "h264_v4l2m2m")
  rescue
    _ -> false
  end

  @doc """
  Builds the ffmpeg argv for a camera: three outputs (fmp4 on stdout, RTP
  to the plugin port, RTP to the WebRTC hub port) — codec-copy by default,
  or `h264_v4l2m2m` with a probed-fps-derived GOP when the camera opts
  into transcode. `extra_ffmpeg_args` are spliced immediately before `-i`.
  """
  @spec build_argv(
          Cairn.Config.Camera.t(),
          {pos_integer(), pos_integer()},
          String.t(),
          keyword()
        ) :: [String.t()]
  def build_argv(cam, {plugin_port, rtp_port}, timeout_flag, opts \\ []) do
    input_opts =
      cond do
        String.starts_with?(cam.rtsp_url, "rtsp://") ->
          ["-rtsp_transport", "tcp", timeout_flag, "10000000"]

        String.starts_with?(cam.rtsp_url, "http") ->
          # live HTTP stream (e.g. Reolink FLV) — this is where ffmpeg's
          # -reconnect flags actually apply (they are HTTP-protocol options).
          # genpts/discardcorrupt smooth over camera timestamp jitter.
          ~w(-rw_timeout 10000000 -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5
             -fflags +genpts+discardcorrupt)

        true ->
          # local file fixture loop for dev
          ["-re", "-stream_loop", "-1"]
      end

    codec_args =
      if cam.transcode do
        gop = Keyword.get(opts, :gop, 40)
        ["-c:v", "h264_v4l2m2m", "-g", "#{gop}", "-bf", "0"]
      else
        ["-c:v", "copy"]
      end

    # RTP consumers (plugins, WebRTC browsers) need SPS/PPS **in-band**:
    # container sources like FLV keep them in extradata only, and ffmpeg's
    # RTP mux would otherwise only advertise them in its own SDP, which
    # never reaches our consumers. No-op for already-annexb sources (RTSP).
    rtp_bsf = ["-bsf:v", "h264_mp4toannexb"]

    ["ffmpeg", "-nostdin", "-nostats", "-loglevel", "warning"] ++
      input_opts ++
      cam.extra_ffmpeg_args ++
      ["-i", cam.rtsp_url] ++
      ["-map", "0:v"] ++
      codec_args ++
      ~w(-f mp4 -movflags +frag_keyframe+empty_moov+default_base_moof
         -frag_duration 2000000 pipe:1) ++
      ["-map", "0:v"] ++
      codec_args ++
      rtp_bsf ++
      ~w(-f rtp -payload_type 96 rtp://127.0.0.1:#{plugin_port}) ++
      ["-map", "0:v"] ++
      codec_args ++
      rtp_bsf ++ ~w(-f rtp -payload_type 96 rtp://127.0.0.1:#{rtp_port})
  end

  @doc "Shell command wrapping `argv` with exec + stderr redirection."
  @spec shell_command([String.t()], Path.t()) :: String.t()
  def shell_command(argv, stderr_log) do
    "exec " <> Enum.map_join(argv, " ", &shell_escape/1) <> " 2>> " <> shell_escape(stderr_log)
  end

  defp shell_escape(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      camera: Keyword.fetch!(opts, :camera),
      config: Keyword.fetch!(opts, :config),
      index: Keyword.get(opts, :index, 0),
      backoff_ms: Keyword.get(opts, :backoff_min_ms, @backoff_min_ms),
      opts: opts
    }

    send(self(), :spawn)
    schedule_watchdog(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:spawn, state) do
    if state.camera.transcode and not transcode_capable?(state) do
      # settled decision: refuse loudly, never fall back to libx264.
      # Re-check occasionally so a driver/module fix is picked up without
      # a full restart.
      Logger.error(
        "camera #{state.camera.id}: transcode requested but h264_v4l2m2m is unavailable — " <>
          "refusing to start (no software fallback)"
      )

      :persistent_term.erase({__MODULE__, :v4l2m2m})
      Process.send_after(self(), :spawn, Keyword.get(state.opts, :recheck_ms, 60_000))
      {:noreply, set_status(state, :transcode_unavailable)}
    else
      {:noreply, spawn_ffmpeg(state)}
    end
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {demuxer, events} = Demuxer.push(state.demuxer, data)
    state = Enum.reduce(events, %{state | demuxer: demuxer}, &handle_event/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("camera #{state.camera.id}: ffmpeg exited with status #{status}")
    {:noreply, enter_backoff(%{state | port: nil, os_pid: nil}, :source_lost)}
  end

  def handle_info(:watchdog, state) do
    schedule_watchdog(state)

    case stalled?(state) do
      true ->
        Logger.warning("camera #{state.camera.id}: stalled (no fragments), bouncing ffmpeg")
        state = set_status(state, :stalled)
        {:noreply, enter_backoff(kill_port(state), :stall_bounce)}

      false ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    {:noreply, enter_backoff(%{state | port: nil, os_pid: nil}, :source_lost)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    kill_port(state)
    # tells epoch subscribers the stream ended; the minted epoch is one
    # nothing ever streams under
    Cairn.StreamEpochs.new_epoch(state.camera.id, :camera_stopped)
    :ok
  end

  # -- internals --------------------------------------------------------------

  defp transcode_capable?(state) do
    Keyword.get_lazy(state.opts, :transcode_available, &transcode_available?/0)
  end

  defp handle_event({:init, %{data: data, codec: codec, timescale: timescale}}, state) do
    Cairn.RingBuffer.put_init(state.camera.id, data, codec, timescale, state.epoch)
    state
  end

  defp handle_event({:fragment, frag}, state) do
    Cairn.RingBuffer.put_fragment(state.camera.id, frag)

    if state.got_fragment do
      state
    else
      state = set_status(state, :running)
      %{state | got_fragment: true, backoff_ms: backoff_min(state)}
    end
  end

  defp handle_event({:error, reason}, state) do
    Logger.warning("camera #{state.camera.id}: fmp4 desync #{inspect(reason)}, bouncing ffmpeg")
    enter_backoff(kill_port(state), :source_lost)
  end

  defp spawn_ffmpeg(state) do
    command = spawn_command(state)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        args: ["-c", command]
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    state = set_status(state, :connecting)
    epoch = Cairn.StreamEpochs.new_epoch(state.camera.id, state.spawn_reason)

    %{
      state
      | port: port,
        os_pid: os_pid,
        demuxer: Demuxer.new(state.camera.id),
        got_fragment: false,
        epoch: epoch
    }
  end

  defp spawn_command(state) do
    case Keyword.get(state.opts, :command) do
      nil ->
        log =
          Path.join(Cairn.DataDir.log_dir(state.config.data_dir), "ffmpeg-#{state.camera.id}.log")

        ports = Cairn.UDPPorts.ports_for(state.config, state.index)

        state.camera
        |> build_argv(ports, timeout_flag(), gop: gop_from_probe(state.camera.id))
        |> shell_command(log)

      command when is_binary(command) ->
        command
    end
  end

  defp enter_backoff(state, reason) do
    state = state |> kill_port() |> set_status(:backoff)
    jitter = :rand.uniform()
    delay = trunc(state.backoff_ms * (0.5 + jitter))
    Process.send_after(self(), :spawn, delay)
    %{state | backoff_ms: min(state.backoff_ms * 2, backoff_max(state)), spawn_reason: reason}
  end

  defp kill_port(%{port: nil} = state), do: state

  defp kill_port(state) do
    if state.os_pid, do: System.cmd("kill", ["-TERM", "#{state.os_pid}"], stderr_to_stdout: true)

    catch_close(state.port)
    %{state | port: nil, os_pid: nil}
  end

  defp catch_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp stalled?(%{status: :running} = state) do
    stall_ms = state.config.stall_seconds * 1_000

    case Cairn.RingBuffer.last_fragment_at(state.camera.id) do
      nil -> false
      at -> System.monotonic_time(:millisecond) - at > stall_ms
    end
  end

  defp stalled?(_state), do: false

  defp schedule_watchdog(state) do
    interval = Keyword.get(state.opts, :watchdog_interval_ms, 5_000)
    Process.send_after(self(), :watchdog, interval)
  end

  defp set_status(%{status: status} = state, status), do: state

  defp set_status(state, status) do
    status_fun = Keyword.get(state.opts, :status_fun, &Cairn.CameraStatus.set/2)
    status_fun.(state.camera.id, status)
    %{state | status: status}
  end

  # GOP = 2 x probed fps (respawns pick up the probe; first spawn defaults)
  defp gop_from_probe(camera_id) do
    case Cairn.CameraStatus.get(camera_id) do
      %{probe: %{fps: fps}} when is_number(fps) and fps > 0 -> round(2 * fps)
      _ -> 40
    end
  end

  defp backoff_min(state), do: Keyword.get(state.opts, :backoff_min_ms, @backoff_min_ms)
  defp backoff_max(state), do: Keyword.get(state.opts, :backoff_max_ms, @backoff_max_ms)
end
