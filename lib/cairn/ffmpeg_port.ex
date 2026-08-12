defmodule Cairn.FFmpegPort do
  @moduledoc """
  Owns one bridge camera's ffmpeg process as a Port, and nothing else. Cameras
  on `ingest: rtsp` have no such process and no such owner — their sessions
  live inside `Membrane.RTSPDualStream.Source`.

  ffmpeg spawns via `/bin/sh -c "exec ffmpeg ... 2>> {data_dir}/log/
  ffmpeg-{id}.log"` so stdout stays a clean media byte stream (stderr can
  neither be merged nor silently dropped) and Port signals reach the real
  ffmpeg thanks to `exec`. stdout carries MPEG-TS — a container with pts, per
  D-M8 — forwarded to `Cairn.Pipeline.BridgeSource`, which this process
  resolves through `Cairn.Registry` and monitors. That element outlives every
  ffmpeg spawned here (D5), so an ffmpeg death is an in-band
  `{:bridge_session_closed, reason}` and not a teardown: the pipeline cuts its
  own recording branch on it, flushing the muxer's held tail, and mints the
  next epoch when media resumes.

  Reconnect policy lives *inside* this GenServer: on `:exit_status` it enters a
  jittered backoff (1s -> 30s) and respawns itself — a dead camera is a normal
  long-lived state and must not burn supervisor restart intensity.
  `bounce/1` is the same path driven from outside, by
  `Cairn.PipelineOwner`'s watchdog, and is the only reason carried across it:
  a bounced session is `:stall_bounce`, any other end is `:closed`.

  ## Status

  Reported through `:status_fun` (wired to `Cairn.CameraStatus`), but only for
  what the pipeline cannot see: this connection's own `:connecting`/`:backoff`
  and the `:transcode_unavailable` refusal. `:running` is deliberately not
  reported here — media flowing is the ring's answer and `Cairn.PipelineOwner`
  gives it, so a bridge that connects and never decodes cannot read as healthy.
  """

  use GenServer

  require Logger

  @backoff_min_ms 1_000
  @backoff_max_ms 30_000

  # TS bytes held before the pipeline's BridgeSource has ever been resolved —
  # the startup window, milliseconds unless the pipeline is failing to start at
  # all. The cap only bounds memory in that interval.
  @pending_max_bytes 8 * 1024 * 1024

  defstruct camera: nil,
            config: nil,
            port: nil,
            os_pid: nil,
            # :init so the first real transition (:connecting) is always emitted
            status: :init,
            backoff_ms: nil,
            opts: [],
            # the camera's BridgeSource, resolved from the registry on the
            # first byte and monitored; `resolved?` is what turns the startup
            # buffer below into a plain drop, since after it an unresolvable
            # send means the pipeline is being rebuilt and its media is a lost
            # session rather than a backlog
            source: nil,
            source_ref: nil,
            resolved?: false,
            resolving?: false,
            pending: [],
            pending_bytes: 0,
            dropped_bytes: 0,
            logged_drop?: false

  def start_link(opts) do
    cam = Keyword.fetch!(opts, :camera)
    GenServer.start_link(__MODULE__, opts, name: Cairn.Registry.via(cam.id, :ffmpeg))
  end

  @doc """
  Kills the current ffmpeg and respawns it through the normal backoff path,
  cutting the session as `:stall_bounce`.

  The watchdog's first rung: a silently wedged TCP session looks exactly like a
  healthy one from here, and re-dialling the camera is cheaper than rebuilding
  the pipeline behind it.
  """
  @spec bounce(GenServer.server()) :: :ok
  def bounce(server), do: GenServer.cast(server, :bounce)

  @doc """
  Is an ffmpeg currently spawned (as opposed to backing off)?

  The watchdog's way of telling an outage from a wedge: a bridge that is not
  running is already recovering itself.
  """
  @spec running?(GenServer.server()) :: boolean()
  def running?(server) do
    GenServer.call(server, :running?, 1_000)
  catch
    :exit, _dead_or_slow -> false
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
  The bridge argv: one output, MPEG-TS on stdout — a container with pts,
  per D-M8: raw Annex-B would lose timestamps the ObservationClock and
  Fragment pts derivation need. Codec-copy by default, or `h264_v4l2m2m`
  with a probed-fps-derived GOP when the camera opts into transcode.
  `extra_ffmpeg_args` are spliced immediately before `-i`.

  No RTP outputs and no UDP ports: the WebRTC hub is fed by the pipeline's
  RTP branch and detection by its `Cairn.Pipeline.Inference`, both
  in-process.
  """
  @spec build_argv(Cairn.Config.Camera.t(), String.t(), keyword()) :: [String.t()]
  def build_argv(cam, timeout_flag, opts \\ []) do
    input_opts = input_opts(cam, timeout_flag)

    codec_args =
      if cam.transcode do
        gop = Keyword.get(opts, :gop, 40)
        ["-c:v", "h264_v4l2m2m", "-g", "#{gop}", "-bf", "0"]
      else
        ["-c:v", "copy"]
      end

    ["ffmpeg", "-nostdin", "-nostats", "-loglevel", "warning"] ++
      input_opts ++
      cam.extra_ffmpeg_args ++
      ["-i", cam.rtsp_url] ++
      ["-map", "0:v"] ++ codec_args ++ ~w(-f mpegts pipe:1)
  end

  defp input_opts(cam, timeout_flag) do
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
      backoff_ms: Keyword.get(opts, :backoff_min_ms, @backoff_min_ms),
      opts: opts
    }

    send(self(), :spawn)
    {:ok, state}
  end

  @impl true
  def handle_call(:running?, _from, state), do: {:reply, state.port != nil, state}

  # A bounce with no port is already what a bounce produces: backing off with a
  # respawn scheduled. Entering it twice would put two ffmpegs on the camera.
  @impl true
  def handle_cast(:bounce, %{port: nil} = state), do: {:noreply, state}

  def handle_cast(:bounce, state) do
    {:noreply, enter_backoff(kill_port(state), :stall_bounce)}
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
    {:noreply, forward_ts(state, data)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("camera #{state.camera.id}: ffmpeg exited with status #{status}")
    {:noreply, enter_backoff(%{state | port: nil, os_pid: nil}, :closed)}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    {:noreply, enter_backoff(%{state | port: nil, os_pid: nil}, :closed)}
  end

  # The pipeline was rebuilt (or died) under us: the next byte re-resolves.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{source_ref: ref} = state) do
    {:noreply, %{state | source: nil, source_ref: nil}}
  end

  # The startup race, and the reason resolution cannot ride the byte stream
  # alone: a camera whose first burst arrives before the pipeline is playing
  # may then go quiet for its whole GOP, and nothing would go looking for the
  # source it is waiting on.
  def handle_info(:resolve, state) do
    {:noreply, state |> Map.put(:resolving?, false) |> resolve_source() |> schedule_resolve()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # The epoch bookkeeping of a deliberate stop belongs to
    # `Cairn.PipelineOwner`, which outlives the pipeline this session feeds;
    # all that is owed here is the OS process.
    kill_port(state)
    :ok
  end

  # -- internals --------------------------------------------------------------

  defp transcode_capable?(state) do
    Keyword.get_lazy(state.opts, :transcode_available, &transcode_available?/0)
  end

  defp spawn_ffmpeg(state) do
    command = spawn_command(state)

    # Nothing between acquiring the port and folding it into state may fail: an
    # unwind there would leave an ffmpeg holding the RTSP session with its pid
    # nowhere in state, so `kill_port/1` would no-op on it.
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
    %{state | port: port, os_pid: os_pid, logged_drop?: false}
  end

  defp spawn_command(state) do
    case Keyword.get(state.opts, :command) do
      nil ->
        log =
          Path.join(Cairn.DataDir.log_dir(state.config.data_dir), "ffmpeg-#{state.camera.id}.log")

        gop = gop_from_probe(state.camera.id)
        shell_command(build_argv(state.camera, timeout_flag(), gop: gop), log)

      command when is_binary(command) ->
        command
    end
  end

  defp forward_ts(state, data) do
    # Bytes on stdout are this process's only evidence that the camera answered
    # at all, so they are what resets the backoff ladder — otherwise one long
    # healthy session ending would still respawn at the 30 s ceiling it climbed
    # to weeks earlier.
    state = %{state | backoff_ms: backoff_min(state)}

    case resolve_source(state) do
      %{source: pid} = state when is_pid(pid) ->
        send(pid, {:ts_data, data})
        state

      state ->
        hold(state, data)
    end
  end

  defp resolve_source(%{source: pid} = state) when is_pid(pid), do: state

  defp resolve_source(state) do
    case Cairn.Registry.whereis(state.camera.id, :bridge_source) do
      nil -> state
      pid -> adopt_source(state, pid)
    end
  end

  defp adopt_source(state, pid) do
    Enum.each(Enum.reverse(state.pending), &send(pid, {:ts_data, &1}))

    %{
      state
      | source: pid,
        source_ref: Process.monitor(pid),
        resolved?: true,
        pending: [],
        pending_bytes: 0
    }
  end

  # Only until the source has ever been resolved. Past that a missing source is
  # a pipeline being rebuilt, and holding its bytes would splice two sessions
  # together across the cut the rebuild is.
  defp hold(%{resolved?: true} = state, data), do: drop(state, data)

  defp hold(state, data) do
    if state.pending_bytes + byte_size(data) <= @pending_max_bytes do
      schedule_resolve(%{
        state
        | pending: [data | state.pending],
          pending_bytes: state.pending_bytes + byte_size(data)
      })
    else
      drop(state, data)
    end
  end

  defp schedule_resolve(%{source: nil, resolving?: false, pending: [_ | _]} = state) do
    Process.send_after(self(), :resolve, Keyword.get(state.opts, :resolve_interval_ms, 50))
    %{state | resolving?: true}
  end

  defp schedule_resolve(state), do: state

  # One line per session, not per read: an unresolvable source drops at the
  # camera's full bitrate.
  defp drop(%{logged_drop?: false} = state, data) do
    Logger.warning(
      "camera #{state.camera.id}: dropping TS bytes — no pipeline source " <>
        "(#{state.pending_bytes} bytes buffered)"
    )

    drop(%{state | logged_drop?: true}, data)
  end

  defp drop(state, data), do: %{state | dropped_bytes: state.dropped_bytes + byte_size(data)}

  # The session's end, in band. Everything ffmpeg delivered is ordered ahead of
  # it in the source's mailbox, so the cut lands exactly where its last byte
  # did — which is what lets the muxer's held tail be flushed rather than lost.
  defp close_session(state, reason) do
    state = resolve_source(state)
    if is_pid(state.source), do: send(state.source, {:bridge_session_closed, reason})
    state
  end

  defp enter_backoff(state, reason) do
    state = state |> kill_port() |> close_session(reason) |> set_status(:backoff)
    delay = trunc(state.backoff_ms * (0.5 + :rand.uniform()))
    Process.send_after(self(), :spawn, delay)

    %{
      state
      | backoff_ms: min(state.backoff_ms * 2, backoff_max(state)),
        pending: [],
        pending_bytes: 0
    }
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
