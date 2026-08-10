defmodule Cairn.FFmpegPort do
  @moduledoc """
  Owns one camera's ffmpeg process as a Port.

  Spawns via `/bin/sh -c "exec ffmpeg ... 2>> {data_dir}/log/ffmpeg-{id}.log"`
  so stdout stays a clean media byte stream (stderr can neither be merged nor
  silently dropped) and Port signals reach the real ffmpeg thanks to `exec`.

  What stdout carries — and who consumes it — depends on the camera's
  `pipeline:` setting:

    * `:classic` — fmp4, streamed through `Cairn.MP4.Demuxer` in this
      process; init segments and fragments are cast to the camera's
      `Cairn.RingBuffer`.
    * `:membrane` — MPEG-TS, forwarded to a per-session
      `Cairn.Pipeline.Camera` (started and monitored here, torn down with
      each ffmpeg session) whose sink feeds the same ring. This process
      then learns "media is flowing" from the ring's own broadcasts,
      epoch-gated so a dying session cannot vouch for its successor. On
      ffmpeg exit an end-of-stream is flushed through the pipeline first,
      so the CMAF muxer's held tail segment is recorded rather than lost.

  Reconnect policy lives *inside* this GenServer: on `:exit_status` (and,
  membrane mode, on pipeline death) it enters a jittered backoff (1s -> 30s)
  and respawns itself — a dead camera is a normal long-lived state and must
  not burn supervisor restart intensity. A periodic watchdog bounces ffmpeg
  when the ring has seen no fragment for `stall_seconds` (silent stall,
  e.g. a wedged TCP session).

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

  # Media buffered until the pipeline's source element announces itself
  # (TS bytes on the ffmpeg bridge, samples on rtsp ingest) — a window of
  # milliseconds unless the pipeline is failing, in which case its monitor
  # ends the session; the cap only bounds memory in that interval.
  @pending_max_bytes 8 * 1024 * 1024

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
            spawn_reason: :started,
            # membrane mode: the per-session pipeline, its monitor, the
            # BridgeSource pid once it announced itself, and TS bytes queued
            # until it does. init_seen gates :running on *this* session's
            # init segment — ring events carry no session identity except the
            # epoch on init, so a stale fragment from the dying pipeline must
            # not reset the backoff of the session that replaced it.
            pipeline: nil,
            pipeline_ref: nil,
            source: nil,
            pending: [],
            pending_bytes: 0,
            dropped_bytes: 0,
            init_seen: false,
            # ingest: :rtsp — the RTSP client session (the `rtsp` library's
            # wrapper process, monitored not linked), the video track's
            # control path and RTP clock rate from its SDP. `port`/`os_pid`
            # stay nil for these cameras; everything else — epoch minting,
            # backoff, the fragment watchdog, the flush grace — is shared.
            rtsp: nil,
            rtsp_ref: nil,
            video_path: nil,
            clock_rate: 90_000

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
    input_opts = input_opts(cam, timeout_flag)

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

  @doc """
  The membrane-mode argv: one output, not three. MPEG-TS on stdout — a
  container with pts, per D-M8: raw Annex-B would lose timestamps the
  ObservationClock and Fragment pts derivation need.

  Both RTP outputs are gone because both consumers moved in-process: the
  WebRTC hub is fed by the pipeline's RTP branch and detection by its
  `Cairn.Pipeline.Inference`. A membrane camera therefore binds no UDP port —
  see `Cairn.Camera`, which also keeps it out of any plugin group.
  """
  @spec build_membrane_argv(Cairn.Config.Camera.t(), String.t(), keyword()) :: [String.t()]
  def build_membrane_argv(cam, timeout_flag, opts \\ []) do
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

  @doc """
  Point a running camera's detect branch at a new config without touching
  ffmpeg.

  Membrane mode's `Cairn.Detect.Dispatch` policy is resolved here at each
  session start, so a reload the classic path delivers through
  `Cairn.PluginPort.refresh/3` has to reach the running pipeline's sink the
  same way — otherwise a `record:` edit would sit unapplied until the camera's
  next reconnect. The ffmpeg argv cannot move under a refresh: every field it
  carries is a `Cairn.Config.Server` restart field.
  """
  @spec refresh(GenServer.server(), Cairn.Config.Camera.t(), Cairn.Config.t()) :: :ok
  def refresh(server, %Cairn.Config.Camera{} = camera, %Cairn.Config{} = config) do
    GenServer.cast(server, {:refresh, camera, config})
  end

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

    # Membrane mode has no inline demuxer to observe fragments on, so the
    # :running transition and backoff reset ride the ring's own broadcasts.
    if membrane?(state) do
      Phoenix.PubSub.subscribe(Cairn.PubSub, Cairn.RingBuffer.topic(state.camera.id))
    end

    send(self(), :spawn)
    schedule_watchdog(state)
    {:ok, state}
  end

  @impl true
  def handle_cast({:refresh, camera, config}, state) do
    # Classic mode holds no policy of its own: its detections come from the
    # plugin port, which `Cairn.CameraSupervisor` refreshes directly.
    if membrane?(state) do
      {:noreply, refresh_detect(state, camera, config)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:spawn, state) do
    cond do
      rtsp_ingest?(state) ->
        {:noreply, spawn_rtsp(state)}

      state.camera.transcode and not transcode_capable?(state) ->
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

      true ->
        {:noreply, spawn_ffmpeg(state)}
    end
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) when state.demuxer == nil do
    {:noreply, forward_ts(state, data)}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {demuxer, events} = Demuxer.push(state.demuxer, data)

    state =
      Enum.reduce_while(events, %{state | demuxer: demuxer}, fn event, state ->
        case handle_event(event, state) do
          # a desync bounced ffmpeg: the rest of the batch belongs to the dead
          # session. Folding it on would let a trailing fragment set the status
          # back to :running with no port, and a trailing init segment be
          # tagged with the epoch of the session that just ended.
          %{port: nil} = state -> {:halt, state}
          state -> {:cont, state}
        end
      end)

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("camera #{state.camera.id}: ffmpeg exited with status #{status}")
    state = %{state | port: nil, os_pid: nil}

    # Membrane mode: the CMAF muxer is holding a final sub-min-duration
    # segment that only an end_of_stream flushes. Everything ffmpeg delivered
    # is ordered ahead of :ts_eos in the source's mailbox, so a short grace
    # before teardown turns "drop up to 2 s of recording on every session
    # end" into a flushed tail. Stall bounces skip this: no data was flowing.
    if membrane?(state) and is_pid(state.source) do
      send(state.source, :ts_eos)
      Process.send_after(self(), :flush_done, Keyword.get(state.opts, :flush_grace_ms, 500))
      {:noreply, state}
    else
      {:noreply, enter_backoff(state, :source_lost)}
    end
  end

  def handle_info(:flush_done, %{port: nil, rtsp: nil, pipeline: pipeline} = state)
      when is_pid(pipeline) do
    {:noreply, enter_backoff(state, :source_lost)}
  end

  # The grace period was cut short by another session-ending path (stall
  # bounce, pipeline death) — backoff is already underway.
  def handle_info(:flush_done, state), do: {:noreply, state}

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

  # -- ingest: :rtsp — the client's three message kinds -------------------------

  # Samples arrive one-or-many per message; only the negotiated video track's
  # control path is ours (the fleet advertises no other track, but an SDP is
  # the camera's to write). pts is rescaled from the track's RTP clock to
  # nanoseconds here, where the clock rate is known, so the source element
  # stays a dumb relay.
  def handle_info({:rtsp, client, {path, samples}}, %{rtsp: client} = state) do
    if path == state.video_path do
      {:noreply, Enum.reduce(List.wrap(samples), state, &forward_sample(&2, &1))}
    else
      {:noreply, state}
    end
  end

  # An RTP sequence gap: frames were lost upstream of us. The decoder side
  # already survives holes (the picker's hole rules exist for exactly this);
  # log it so a lossy link is visible in one place.
  def handle_info({:rtsp, client, :discontinuity}, %{rtsp: client} = state) do
    Logger.warning("camera #{state.camera.id}: rtsp discontinuity (rtp sequence gap)")
    {:noreply, state}
  end

  # The session ended — teardown, socket death, or server-side close; the
  # client wrapper stays alive and this message is the whole signal. Same
  # shape as ffmpeg's exit_status: flush the CMAF tail through the source,
  # then back off and respawn under a fresh epoch.
  def handle_info({:rtsp, client, :session_closed}, %{rtsp: client} = state) do
    Logger.warning("camera #{state.camera.id}: rtsp session closed")
    state = kill_rtsp(state)

    if is_pid(state.source) do
      send(state.source, :rtsp_eos)
      Process.send_after(self(), :flush_done, Keyword.get(state.opts, :flush_grace_ms, 500))
      {:noreply, state}
    else
      {:noreply, enter_backoff(state, :source_lost)}
    end
  end

  # A stale session's message (bounced client, late delivery) — not ours.
  def handle_info({:rtsp, _client, _event}, state), do: {:noreply, state}

  # The client process itself died — a crash, not a close (a close leaves it
  # alive and sends :session_closed). Same recovery, including the tail
  # flush: everything the client delivered is ordered ahead of this :DOWN in
  # our mailbox and already forwarded, so the CMAF muxer's held final
  # segment is as recoverable here as on a graceful close.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{rtsp_ref: ref} = state) do
    Logger.warning("camera #{state.camera.id}: rtsp client died: #{inspect(reason)}")
    state = %{state | rtsp: nil, rtsp_ref: nil, video_path: nil}

    if is_pid(state.source) do
      send(state.source, :rtsp_eos)
      Process.send_after(self(), :flush_done, Keyword.get(state.opts, :flush_grace_ms, 500))
      {:noreply, state}
    else
      {:noreply, enter_backoff(state, :source_lost)}
    end
  end

  # Epoch-matched exactly as :bridge_source_ready: a stale element outliving
  # a force-kill cannot claim the successor session's samples.
  def handle_info({:rtsp_source_ready, epoch, pid}, %{epoch: epoch} = state) do
    Enum.each(Enum.reverse(state.pending), fn {payload, pts_ns} ->
      send(pid, {:rtsp_sample, payload, pts_ns})
    end)

    {:noreply, %{state | source: pid, pending: [], pending_bytes: 0}}
  end

  # Epoch-matched so a stale element that outlived a force-kill teardown
  # cannot claim the successor session's byte stream; a mismatched ready
  # falls through to the catch-all and is dropped.
  def handle_info({:bridge_source_ready, epoch, pid}, %{epoch: epoch} = state) do
    Enum.each(Enum.reverse(state.pending), &send(pid, {:ts_data, &1}))
    {:noreply, %{state | source: pid, pending: [], pending_bytes: 0}}
  end

  # A pipeline death is a lost decode session, exactly like ffmpeg dying:
  # same backoff, same epoch semantics. Our own teardown never lands here —
  # `stop_pipeline/1` demonitors with flush first — so any reason, even
  # :normal, is an unexpected end of the session.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{pipeline_ref: ref} = state) do
    Logger.warning("camera #{state.camera.id}: membrane pipeline died: #{inspect(reason)}")
    state = %{state | pipeline: nil, pipeline_ref: nil, source: nil}
    {:noreply, enter_backoff(state, :source_lost)}
  end

  # Ring broadcasts (membrane mode only, see init/1). The init segment carries
  # the epoch, fragments do not — so the epoch match on init is what ties the
  # fragment-based :running transition to *this* spawn. A stale session's
  # fragment cannot slip in after this init: every ring event is emitted by
  # the one per-camera RingBuffer process, whose mailbox already held any
  # old-session casts before the new sink existed to cast its init (local
  # sends enqueue at send time), and PubSub preserves that per-publisher
  # order — plus init_seen is reset by both stop_pipeline/1 and
  # spawn_ffmpeg/1, and the flush-grace window is covered by the port guard
  # below.
  def handle_info({:init_segment, %{epoch: epoch}}, %{epoch: epoch} = state) do
    {:noreply, %{state | init_seen: true}}
  end

  def handle_info({:fragment, _frag}, %{init_seen: true, got_fragment: false} = state)
      when state.port != nil or state.rtsp != nil do
    state = set_status(state, :running)
    {:noreply, %{state | got_fragment: true, backoff_ms: backoff_min(state)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    # Only a deliberate stop ends the stream: after a crash the restart mints
    # its own epoch, and announcing :camera_stopped in between would make
    # consumers see a stopped -> started flap. Minted *before* the blocking
    # kill so it is not the first casualty of the supervisor's shutdown budget.
    # Never a guarantee either way — a brutal kill skips terminate/2 entirely,
    # so consumers must keep their own timeouts as the backstop.
    # Short timeout: shutdown must not be gated on epoch bookkeeping. A wedged
    # StreamEpochs would otherwise eat the shutdown budget and get us killed
    # before kill_port/1, orphaning ffmpeg; the degraded path still
    # best-effort-broadcasts.
    if stop_reason?(reason) do
      Cairn.StreamEpochs.new_epoch(state.camera.id, :camera_stopped, 500)
    end

    state |> kill_port() |> kill_rtsp() |> stop_pipeline()
    :ok
  end

  defp stop_reason?(:normal), do: true
  defp stop_reason?(:shutdown), do: true
  defp stop_reason?({:shutdown, _}), do: true
  defp stop_reason?(_reason), do: false

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

    # Mint before the port exists. Nothing between acquiring the port and
    # folding it into state may fail: an unwind there would leave an ffmpeg
    # holding the RTSP session with its pid nowhere in state, so `kill_port/1`
    # would no-op on it — and on the classic path its UDP ports with it.
    # (`start_session/1` upholds this: a pipeline start failure is handled as
    # a value, never an unwind.)
    epoch = Cairn.StreamEpochs.new_epoch(state.camera.id, state.spawn_reason)

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

    state = %{
      state
      | port: port,
        os_pid: os_pid,
        got_fragment: false,
        init_seen: false,
        epoch: epoch
    }

    start_session(state)
  end

  # One decode session = one RTSP client + one pipeline — spawn_ffmpeg's
  # exact shape with the OS process replaced by the `rtsp` library's client:
  # epoch minted first, failures handled as values (a refused camera enters
  # the same backoff a dead ffmpeg does), the client monitored rather than
  # linked — its normal end is a `:session_closed` message from a process
  # that stays alive, and its crash is the :DOWN.
  defp spawn_rtsp(state) do
    epoch = Cairn.StreamEpochs.new_epoch(state.camera.id, state.spawn_reason)
    state = set_status(state, :connecting)

    case open_rtsp(state) do
      {:ok, client, ref, video_path, clock_rate} ->
        state = %{
          state
          | rtsp: client,
            rtsp_ref: ref,
            video_path: video_path,
            clock_rate: clock_rate,
            got_fragment: false,
            init_seen: false,
            epoch: epoch
        }

        start_session(state)

      {:error, reason} ->
        Logger.warning("camera #{state.camera.id}: rtsp connect failed: #{inspect(reason)}")
        enter_backoff(state, :source_lost)
    end
  end

  # start → connect → exactly one H.264 video track → play, every step a
  # value: a refused start (bad host, exhausted resources) is the same
  # backoff a dead ffmpeg gets, never a MatchError that would crash this
  # process and its backoff/epoch state with it. Any other answer is a
  # camera this ingest cannot serve, refused with the reason in the log —
  # the operator's remedy is `ingest: ffmpeg` (D-M7's escape hatch).
  defp open_rtsp(state) do
    rtsp = rtsp_module(state)

    case rtsp.start(
           stream_uri: state.camera.rtsp_url,
           transport: :tcp,
           # Video only: the default SETUPs and depayloads audio too, which
           # this handler would discard per sample — and an unusable audio
           # track must not be able to refuse an otherwise valid session.
           allowed_media_types: [:video],
           receiver: self()
         ) do
      {:ok, client} ->
        open_session(rtsp, client)

      :ignore ->
        {:error, :ignore}

      {:error, _reason} = error ->
        error
    end
  end

  # `connect/1` and `play/1` are GenServer.calls: a slow camera or a client
  # race EXITS the caller (timeout, :noproc) rather than returning an error,
  # and `with` only handles values — so the exit is caught here and refused
  # through the same cleanup as a returned refusal. Letting it escape would
  # crash this process and its backoff/epoch state with it.
  defp open_session(rtsp, client) do
    ref = Process.monitor(client)

    try do
      with {:ok, tracks} <- rtsp.connect(client),
           {:ok, video_path, clock_rate} <- video_track(tracks),
           :ok <- rtsp.play(client) do
        {:ok, client, ref, video_path, clock_rate}
      else
        error -> refuse_session(rtsp, client, ref, normalize_error(error))
      end
    catch
      :exit, reason -> refuse_session(rtsp, client, ref, {:error, {:exit, reason}})
    end
  end

  defp refuse_session(rtsp, client, ref, error) do
    Process.demonitor(ref, [:flush])
    stop_client_async(rtsp, client)
    error
  end

  defp normalize_error({:error, _reason} = error), do: error
  defp normalize_error(other), do: {:error, other}

  defp video_track(tracks) do
    case Enum.filter(tracks, &(&1.type == :video)) do
      [%{control_path: path, rtpmap: %{encoding: "H264"} = rtpmap}] ->
        {:ok, path, rtpmap.clock_rate}

      [%{rtpmap: %{encoding: encoding}}] ->
        {:error, {:unsupported_codec, encoding}}

      # An SDP may legally omit the rtpmap; without it there is no encoding
      # and no clock rate to build a session on — named distinctly so the
      # operator is not sent hunting for a second video track.
      [_track] ->
        {:error, :no_rtp_metadata}

      [] ->
        {:error, :no_video_track}

      [_, _ | _] ->
        {:error, :multiple_video_tracks}
    end
  end

  defp forward_sample(state, {payload, pts, _keyframe?, _wallclock_ms}) do
    payload = IO.iodata_to_binary(payload)
    pts_ns = div(pts * 1_000_000_000, state.clock_rate)

    case state.source do
      pid when is_pid(pid) ->
        send(pid, {:rtsp_sample, payload, pts_ns})
        state

      nil ->
        pend_sample(state, payload, pts_ns)
    end
  end

  # The same bounded holding pattern as forward_ts/2, for the window between
  # PLAY and the source element announcing itself.
  defp pend_sample(state, payload, pts_ns) do
    cond do
      state.pending_bytes + byte_size(payload) <= @pending_max_bytes ->
        %{
          state
          | pending: [{payload, pts_ns} | state.pending],
            pending_bytes: state.pending_bytes + byte_size(payload)
        }

      state.dropped_bytes == 0 ->
        Logger.warning(
          "camera #{state.camera.id}: dropping rtsp samples — pipeline source " <>
            "not ready after #{@pending_max_bytes} buffered bytes"
        )

        %{state | dropped_bytes: byte_size(payload)}

      true ->
        %{state | dropped_bytes: state.dropped_bytes + byte_size(payload)}
    end
  end

  defp kill_rtsp(%{rtsp: nil} = state), do: state

  defp kill_rtsp(state) do
    Process.demonitor(state.rtsp_ref, [:flush])
    stop_client_async(rtsp_module(state), state.rtsp)
    %{state | rtsp: nil, rtsp_ref: nil, video_path: nil}
  end

  # Off this process's loop, every time: the library's `stop/1` is a
  # synchronous call into a client that may be wedged, and the camera's
  # message loop must not be — `kill_port/1`'s TERM is non-blocking for the
  # same reason. The caller has already flushed its monitor, so teardown
  # owes it nothing; the backstop kill bounds a graceful stop that never
  # returns (the client holds only its socket, which dies with it).
  #
  # The kill after a *successful* stop is not paranoia: the library's
  # `stop/1` cleans the session and replies but deliberately leaves its
  # GenServer alive — without it, every normal teardown would leak one
  # unmonitored client process.
  defp stop_client_async(rtsp, client) do
    spawn(fn ->
      {_stopper, ref} = spawn_monitor(fn -> stop_then_reap(rtsp, client) end)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        3_000 -> Process.exit(client, :kill)
      end
    end)
  end

  defp stop_then_reap(rtsp, client) do
    catch_stop(rtsp, client)
    if Process.alive?(client), do: Process.exit(client, :kill)
  end

  # `stop/1` on a client that already closed (or crashed) must not take the
  # teardown process with it — the session is ending either way.
  defp catch_stop(rtsp, client) do
    rtsp.stop(client)
  catch
    :exit, _reason -> :ok
  end

  defp rtsp_ingest?(state), do: state.camera.ingest == :rtsp

  defp rtsp_module(state), do: Keyword.get(state.opts, :rtsp_module, RTSP)

  # One decode session = one ffmpeg + (membrane mode) one pipeline: the TS
  # demuxer's state is per-session, so the pipeline is born and dies with its
  # ffmpeg rather than living in the supervision tree where a restart would
  # decouple the two.
  defp start_session(state) do
    if membrane?(state) do
      opts = [
        camera: state.camera,
        epoch: state.epoch,
        owner: self(),
        ingest: state.camera.ingest,
        detect: detect_opts(state)
      ]

      module = Keyword.get(state.opts, :pipeline_module, Cairn.Pipeline.Camera)

      case Membrane.Pipeline.start(module, opts) do
        {:ok, _supervisor, pipeline} ->
          %{state | pipeline: pipeline, pipeline_ref: Process.monitor(pipeline)}

        {:error, reason} ->
          Logger.error(
            "camera #{state.camera.id}: membrane pipeline failed to start: #{inspect(reason)}"
          )

          enter_backoff(state, :source_lost)
      end
    else
      %{state | demuxer: Demuxer.new(state.camera.id)}
    end
  end

  defp spawn_command(state) do
    case Keyword.get(state.opts, :command) do
      nil ->
        log =
          Path.join(Cairn.DataDir.log_dir(state.config.data_dir), "ffmpeg-#{state.camera.id}.log")

        gop = gop_from_probe(state.camera.id)

        # The allocation is only reached on the classic path: a membrane
        # camera's argv carries no port, and its index slot stays reserved
        # anyway (`Cairn.UDPPorts` is positional).
        argv =
          if membrane?(state) do
            build_membrane_argv(state.camera, timeout_flag(), gop: gop)
          else
            ports = Cairn.UDPPorts.ports_for(state.config, state.index)
            build_argv(state.camera, ports, timeout_flag(), gop: gop)
          end

        shell_command(argv, log)

      command when is_binary(command) ->
        command
    end
  end

  defp membrane?(state), do: state.camera.pipeline == :membrane

  # `send/2` and not a pipeline call: a refresh must not wait on a pipeline
  # whose sink is inside a `push_frame/5`. Between sessions there is no pipeline to
  # tell and none is owed — the next spawn resolves the policy from `config`.
  defp refresh_detect(state, camera, config) do
    state = %{state | camera: camera, config: config}

    if is_pid(state.pipeline) do
      send(state.pipeline, {:policy, camera, Cairn.Config.policy(config, camera)})
    end

    state
  end

  # `nil` leaves the pipeline's detect branch unbuilt. `min_score` is the same
  # wire floor the plugin argv carries on the classic path; the rest of the
  # profile is still the plugin's own and becomes engine config later.
  # `policy:` is resolved here rather than in the sink for the reason the plugin
  # ports resolve it at init: it is a config round trip, and the sink's caller
  # is the per-frame path.
  defp detect_opts(%{camera: %{plugin: nil}}), do: nil

  # No `sample_fps`: the branch does not thin, and the engine takes the rate from
  # the profile every membrane camera on this node has to agree on
  # (`Cairn.Config.native_model_config/1`).
  defp detect_opts(state) do
    [
      policy: Cairn.Config.policy(state.config, state.camera),
      stream_params: %{min_score: state.camera.min_score}
    ]
  end

  defp forward_ts(%{source: pid} = state, data) when is_pid(pid) do
    send(pid, {:ts_data, data})
    state
  end

  defp forward_ts(state, data) do
    cond do
      state.pending_bytes + byte_size(data) <= @pending_max_bytes ->
        %{
          state
          | pending: [data | state.pending],
            pending_bytes: state.pending_bytes + byte_size(data)
        }

      state.dropped_bytes == 0 ->
        Logger.warning(
          "camera #{state.camera.id}: dropping TS bytes — pipeline source " <>
            "not ready after #{@pending_max_bytes} buffered bytes"
        )

        %{state | dropped_bytes: byte_size(data)}

      true ->
        %{state | dropped_bytes: state.dropped_bytes + byte_size(data)}
    end
  end

  defp stop_pipeline(%{pipeline: nil} = state), do: state

  defp stop_pipeline(state) do
    Process.demonitor(state.pipeline_ref, [:flush])
    # force?: a wedged element must not block the respawn path; the pipeline
    # holds no OS resources, so a hard kill leaks nothing.
    Membrane.Pipeline.terminate(state.pipeline, timeout: 5_000, force?: true)

    %{
      state
      | pipeline: nil,
        pipeline_ref: nil,
        source: nil,
        pending: [],
        pending_bytes: 0,
        dropped_bytes: 0,
        init_seen: false
    }
  end

  defp enter_backoff(state, reason) do
    state = state |> kill_port() |> kill_rtsp() |> stop_pipeline() |> set_status(:backoff)
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
