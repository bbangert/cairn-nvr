defmodule Membrane.RTSPDualStream.Source do
  @moduledoc """
  A push source that owns its RTSP client session(s) and outlives them: the
  camera's main and sub stream are connected, lost, and reconnected entirely
  inside this element, so the pipeline around it is built once and never
  rebuilt.

  That placement is the whole point. A dead camera is a normal long-lived
  state, not a fault: absorbing reconnect here keeps it from burning
  supervisor restart intensity, and keeps backoff state from dying with a
  pipeline crash.

  ## Roles

  A role runs iff its URI is configured, so the element covers main-only,
  sub-only (an ffmpeg bridge owns main elsewhere) and both. Everything a
  session has — client, backoff ladder, retry timer, drop-until-IDR,
  format synthesis, in-band events — is per role, and nothing recovers one
  role onto the other: a sub that never comes back retries forever rather
  than falling back to main, which is a config-time choice only.

  ## Pads

  One `:output` pad, `availability: :on_request`, whose **pad id is the
  stream role** — `Pad.ref(:output, :main)` and `Pad.ref(:output, :sub)`.
  Samples for a role with no linked pad are dropped.

  ## Parent notifications

    * `{:stream_connected, role, tracks}` — a session is live; `tracks` is
      verbatim from the client's `connect/1`. The parent compares track
      identity across reconnects and decides whether its branch needs a
      rebuild; a changed control path or clock rate is absorbed here as a
      value, never a crash.
    * `{:stream_backoff, role, reason}` — this attempt failed (refusal,
      caught exit, unusable SDP); a retry is scheduled.
    * `{:stream_lost, role}` — a live session ended.

  ## In-band vocabulary

    * `Membrane.Event.Discontinuity` — mid-session RTP loss, session still
      up; the client already dropped its half-built access unit.
    * `Membrane.RTSPDualStream.Event.StreamClosed` — the session ended;
      what follows belongs to a new one.

  Both are emitted only for a session that actually produced buffers, so a
  camera that never streams cannot flood downstream with resets.

  ## Parent notifications in

    * `:eos` — graceful stop. Every linked pad that carries a stream format
      is ended, sessions are cleaned and reconnecting stops for good. It is
      how a parent about to terminate the pipeline gets a muxer's held tail
      flushed; the element is not reusable afterwards.

  ## Format per session

  Each session drops buffers until its first keyframe, then synthesises
  `%Membrane.H264{}` from the SPS the client prepends to every keyframe
  access unit and emits it ahead of that buffer. The format is re-emitted
  for every session even when byte-identical to the last: a session
  boundary is a format boundary downstream, where decoders and muxers key
  their reset off the format.
  """

  use Membrane.Source

  require Membrane.Logger

  alias MediaCodecs.H264.NALU
  alias Membrane.{Buffer, H264, Pad, ResourceGuard, Time}
  alias Membrane.RTSPDualStream.Event.StreamClosed

  def_options stream_uri: [
                spec: String.t() | nil,
                default: nil,
                description: "RTSP URI of the main stream, or nil to run sub-only"
              ],
              substream_uri: [
                spec: String.t() | nil,
                default: nil,
                description: "RTSP URI of the sub stream, or nil for main-only"
              ],
              rtsp_module: [
                spec: module(),
                default: RTSP,
                description: "The RTSP client implementation (injection seam for tests)"
              ],
              backoff_min_ms: [
                spec: pos_integer(),
                default: 1_000,
                description: "First reconnect delay, restored once media flows"
              ],
              backoff_max_ms: [
                spec: pos_integer(),
                default: 30_000,
                description: "Ceiling the doubling reconnect delay stops at"
              ]

  def_output_pad :output,
    availability: :on_request,
    flow_control: :push,
    accepted_format: %H264{alignment: :au}

  @impl true
  def handle_init(_ctx, opts) do
    streams =
      [main: opts.stream_uri, sub: opts.substream_uri]
      |> Enum.reject(fn {_role, uri} -> is_nil(uri) end)
      |> Map.new(fn {role, uri} -> {role, new_stream(role, uri, opts.backoff_min_ms)} end)

    # Refused rather than tolerated: an element that connects nothing and
    # emits nothing is indistinguishable downstream from a dead camera.
    if map_size(streams) == 0 do
      raise ArgumentError, "#{inspect(__MODULE__)}: set stream_uri, substream_uri, or both"
    end

    state = %{
      rtsp_module: opts.rtsp_module,
      backoff_min_ms: opts.backoff_min_ms,
      backoff_max_ms: opts.backoff_max_ms,
      streams: streams,
      stopped?: false
    }

    {[], state}
  end

  @impl true
  def handle_playing(ctx, state) do
    Enum.reduce(Map.keys(state.streams), {[], state}, fn role, {actions, state} ->
      {new_actions, state} = connect(role, ctx, state)
      {actions ++ new_actions, state}
    end)
  end

  @impl true
  def handle_tick({:reconnect, role}, ctx, state) do
    state = put_stream(state, %{state.streams[role] | retrying?: false})
    {actions, state} = connect(role, ctx, state)
    {[stop_timer: {:reconnect, role}] ++ actions, state}
  end

  @impl true
  def handle_parent_notification(:eos, ctx, state) do
    actions =
      Enum.flat_map(state.streams, fn {role, stream} ->
        cancel(stream) ++ eos(pad(role), ctx)
      end)

    streams =
      Map.new(state.streams, fn {role, stream} ->
        stream = clean_client(stream, ctx.resource_guard, state.rtsp_module)
        {role, %{stream | retrying?: false}}
      end)

    {actions, %{state | streams: streams, stopped?: true}}
  end

  @impl true
  def handle_info({:rtsp, client, {path, samples}}, ctx, state) do
    case stream_for_client(state, client) do
      %{control_path: ^path} = stream ->
        if pad_linked?(ctx, stream.role) do
          {actions, stream} =
            samples
            |> List.wrap()
            |> Enum.reduce({[], stream}, &forward_sample(&1, &2, state.backoff_min_ms))

          {actions, put_stream(state, stream)}
        else
          {[], state}
        end

      # Another track's control path, or a stale client's late delivery.
      _other ->
        {[], state}
    end
  end

  @impl true
  def handle_info({:rtsp, client, :discontinuity}, ctx, state) do
    case stream_for_client(state, client) do
      nil ->
        {[], state}

      stream ->
        Membrane.Logger.warning("#{stream.role} stream: rtp sequence gap")
        {emit(stream, ctx, %Membrane.Event.Discontinuity{}), state}
    end
  end

  @impl true
  def handle_info({:rtsp, client, :session_closed}, ctx, state) do
    case stream_for_client(state, client) do
      nil -> {[], state}
      stream -> lose_session(stream, :session_closed, ctx, state)
    end
  end

  # A client crash rather than a close: the library's `stop/1` and a
  # server-side close both leave the client process alive and send
  # `:session_closed`, so this is only ever the abnormal end.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, ctx, state) do
    case Enum.find_value(state.streams, fn {_role, s} -> s.monitor == ref && s end) do
      nil -> {[], state}
      stream -> lose_session(stream, {:client_down, reason}, ctx, state)
    end
  end

  @impl true
  def handle_info(msg, _ctx, state) do
    Membrane.Logger.warning("unexpected message: #{inspect(msg)}")
    {[], state}
  end

  defp new_stream(role, uri, backoff_ms) do
    %{
      role: role,
      uri: uri,
      client: nil,
      monitor: nil,
      control_path: nil,
      clock_rate: nil,
      backoff_ms: backoff_ms,
      # whether a reconnect timer is pending — `stop_timer` on one that was
      # never started raises, so a graceful stop has to know
      retrying?: false,
      # drop-until-IDR, re-armed for every session
      awaiting_keyframe?: true,
      # whether *this* session has put a buffer on the pad — the gate on the
      # in-band events, which would otherwise announce the death of a
      # session downstream never saw
      emitted?: false
    }
  end

  # Connecting blocks the element: the same tradeoff ex_nvr and the ffmpeg
  # ingest make. Nothing else this element does is more urgent than getting
  # media flowing, and the alternative — a helper process — reintroduces the
  # ownership split this element exists to remove.
  #
  # It is also the only thing the two roles share: one role's handshake
  # delays the other's samples and its retry tick for the duration. Bounded
  # by the client's own call timeouts (the exit is caught in `open_session`),
  # and it moves nothing between the roles — no state, no fallback.
  defp connect(_role, _ctx, %{stopped?: true} = state), do: {[], state}

  defp connect(role, ctx, state) do
    stream = state.streams[role]

    case open(state.rtsp_module, stream.uri) do
      {:ok, client, monitor, tracks, path, clock_rate} ->
        # The guard, not handle_terminate_request: it also fires when the
        # element crashes, which is exactly when a client would be orphaned.
        ResourceGuard.register(
          ctx.resource_guard,
          fn -> stop_client_async(state.rtsp_module, client) end,
          tag: {:rtsp_client, client}
        )

        stream = %{
          stream
          | client: client,
            monitor: monitor,
            control_path: path,
            clock_rate: clock_rate,
            awaiting_keyframe?: true,
            emitted?: false
        }

        {[notify_parent: {:stream_connected, role, tracks}], put_stream(state, stream)}

      {:error, reason} ->
        backoff(stream, reason, state)
    end
  end

  # A fresh client per session. The library would allow reuse — `clean/1`
  # resets a closed session to `:init` — but this element kills its clients
  # on teardown, and a crashed one is unusable anyway.
  defp open(rtsp, uri) do
    case rtsp.start(
           stream_uri: uri,
           transport: :tcp,
           # Video only: the default SETUPs and depayloads audio too, which
           # this element would discard per sample — and an unusable audio
           # track must not be able to refuse an otherwise valid session.
           allowed_media_types: [:video],
           receiver: self()
         ) do
      {:ok, client} -> open_session(rtsp, client)
      :ignore -> {:error, :ignore}
      {:error, _reason} = error -> error
    end
  end

  # `connect/1` and `play/1` are GenServer.calls: a slow camera or a client
  # race EXITS the caller (timeout, :noproc) rather than returning an error,
  # and `with` only handles values — so the exit is caught here and refused
  # through the same cleanup as a returned refusal. Letting it escape would
  # crash the element and take every other role's session with it.
  defp open_session(rtsp, client) do
    monitor = Process.monitor(client)

    try do
      with {:ok, tracks} <- rtsp.connect(client),
           {:ok, path, clock_rate} <- video_track(tracks),
           :ok <- rtsp.play(client) do
        {:ok, client, monitor, tracks, path, clock_rate}
      else
        error -> refuse(rtsp, client, monitor, normalize_error(error))
      end
    catch
      :exit, reason -> refuse(rtsp, client, monitor, {:error, {:exit, reason}})
    end
  end

  defp refuse(rtsp, client, monitor, error) do
    Process.demonitor(monitor, [:flush])
    stop_client_async(rtsp, client)
    error
  end

  defp normalize_error({:error, _reason} = error), do: error
  defp normalize_error(other), do: {:error, other}

  defp video_track(tracks) do
    case Enum.filter(tracks, &(&1.type == :video)) do
      [%{control_path: path, rtpmap: %{encoding: encoding} = rtpmap}] ->
        # SDP encoding names are case-insensitive and ExSDP preserves the
        # camera's spelling — `h264/90000` is as valid as `H264/90000`. The
        # refusal carries the original spelling for the operator.
        if String.upcase(encoding) == "H264" do
          {:ok, path, rtpmap.clock_rate}
        else
          {:error, {:unsupported_codec, encoding}}
        end

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

  defp lose_session(stream, reason, ctx, state) do
    Membrane.Logger.warning("#{stream.role} stream ended: #{inspect(reason)}")

    events = emit(stream, ctx, %StreamClosed{})
    stream = stream |> clean_client(ctx.resource_guard, state.rtsp_module) |> rearm()
    {retry, state} = backoff(stream, reason, state)

    {events ++ [notify_parent: {:stream_lost, stream.role}] ++ retry, state}
  end

  defp rearm(stream), do: %{stream | awaiting_keyframe?: true, emitted?: false}

  defp clean_client(%{client: nil} = stream, _guard, _rtsp), do: stream

  defp clean_client(stream, guard, rtsp) do
    Process.demonitor(stream.monitor, [:flush])
    ResourceGuard.unregister(guard, {:rtsp_client, stream.client})
    stop_client_async(rtsp, stream.client)
    %{stream | client: nil, monitor: nil}
  end

  # Off the element's loop, every time: the library's `stop/1` is a
  # synchronous call into a client that may be wedged, and a source element
  # must not be. The backstop kill bounds a graceful stop that never returns
  # (the client holds only its socket, which dies with it).
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

  defp backoff(stream, _reason, %{stopped?: true} = state), do: {[], put_stream(state, stream)}

  defp backoff(stream, reason, state) do
    delay = trunc(stream.backoff_ms * (0.5 + :rand.uniform()))

    Membrane.Logger.warning("#{stream.role} stream: #{inspect(reason)}, retrying in #{delay} ms")

    stream = %{
      stream
      | backoff_ms: min(stream.backoff_ms * 2, state.backoff_max_ms),
        retrying?: true
    }

    actions = [
      notify_parent: {:stream_backoff, stream.role, reason},
      start_timer: {{:reconnect, stream.role}, Time.milliseconds(delay)}
    ]

    {actions, put_stream(state, stream)}
  end

  defp cancel(%{retrying?: true, role: role}), do: [stop_timer: {:reconnect, role}]
  defp cancel(_stream), do: []

  # A pad that never carried a format never carried a stream either, and
  # ending one twice is refused.
  defp eos(pad, ctx) do
    case ctx.pads[pad] do
      %{stream_format: format, end_of_stream?: false} when format != nil -> [end_of_stream: pad]
      _unlinked_or_silent_or_ended -> []
    end
  end

  defp forward_sample({payload, pts, keyframe?, _wallclock_ms}, {actions, stream}, backoff_min) do
    nalus = List.wrap(payload)

    cond do
      not stream.awaiting_keyframe? ->
        {actions ++ [buffer: {pad(stream.role), buffer(nalus, pts, keyframe?, stream)}], stream}

      not keyframe? ->
        {actions, stream}

      true ->
        case stream_format(nalus) do
          nil ->
            # A session may not start without a declarable format; keep
            # dropping and wait for a keyframe that carries an SPS.
            Membrane.Logger.warning("#{stream.role} stream: keyframe with no SPS, still dropping")

            {actions, stream}

          format ->
            buffer = buffer(nalus, pts, keyframe?, stream)
            pad = pad(stream.role)

            {actions ++ [stream_format: {pad, format}, buffer: {pad, buffer}],
             %{stream | awaiting_keyframe?: false, emitted?: true, backoff_ms: backoff_min}}
        end
    end
  end

  defp buffer(nalus, pts, keyframe?, stream) do
    %Buffer{
      payload: annexb(nalus),
      pts: div(pts * 1_000_000_000, stream.clock_rate),
      metadata: %{keyframe?: keyframe?}
    }
  end

  # The library's decoder STRIPS start codes at RTP ingest and hands the
  # access unit over as bare NAL binaries — concatenating them as-is would
  # be an invalid byte stream (SPS|PPS|slice with no framing). Annex-B
  # framing is restored here, one 4-byte start code per NAL.
  defp annexb(nalus), do: IO.iodata_to_binary(Enum.map(nalus, &[<<0, 0, 0, 1>>, &1]))

  # The client prepends the current parameter sets to every keyframe access
  # unit, so the format is derivable from the media itself — no out-of-band
  # signalling, and a resolution change after a reconnect propagates within
  # one GOP.
  defp stream_format(nalus) do
    case Enum.find(nalus, &sps?/1) do
      nil ->
        nil

      sps ->
        %NALU{content: sps} = NALU.parse(sps)

        %H264{
          alignment: :au,
          stream_structure: :annexb,
          width: NALU.SPS.width(sps),
          height: NALU.SPS.height(sps),
          profile: NALU.SPS.profile(sps)
        }
    end
  end

  defp sps?(nalu) when is_binary(nalu) and byte_size(nalu) > 0, do: NALU.type(nalu) == :sps
  defp sps?(_nalu), do: false

  defp pad(role), do: Pad.ref(:output, role)

  defp pad_linked?(ctx, role), do: Map.has_key?(ctx.pads, pad(role))

  defp emit(stream, ctx, event) do
    if stream.emitted? and pad_linked?(ctx, stream.role),
      do: [event: {pad(stream.role), event}],
      else: []
  end

  defp stream_for_client(state, client) do
    Enum.find_value(state.streams, fn {_role, stream} -> stream.client == client && stream end)
  end

  defp put_stream(state, stream) do
    %{state | streams: Map.put(state.streams, stream.role, stream)}
  end
end
