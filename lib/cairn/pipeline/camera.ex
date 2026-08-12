defmodule Cairn.Pipeline.Camera do
  @moduledoc """
  One long-lived membrane pipeline per camera. The ingest stage differs by
  `ingest:`; everything from the tagger on is identical:

      ingest: ffmpeg   BridgeSource ─ TS demux ──┐
      ingest: rtsp     RTSPDualStream.Source ────┤
                                                 │
       EpochTagger ─ tee ─┬─ record_cut ─(n)─ parser(avc3) ─ CMAF ─ RingBufferSink
                          ├─ rtp_cut ────(n)─ RTPOut (in-process WebRTC hub feed)
                          └─ Picker ─(manual)─ Decoder ─(manual)─ Inference
                             ─ ObservationStamper ─ MOTTracker ─ TrackSink

  Started once by `Cairn.PipelineOwner` and rebuilt only by it — on a crash or
  a watchdog escalation, never on a reconnect. Connection lifecycle lives in
  the sources (the RTSP client sessions inside the element, the ffmpeg Port
  beside it in `Cairn.FFmpegPort`), and a session boundary reaches the pipeline
  in-band: `StreamClosed` mints a fresh epoch at `Cairn.Pipeline.EpochTagger`
  and cuts the per-session branches at the `Cairn.Pipeline.SessionCut` gates.

  The recording and RTP branches are per session because neither survives one:
  `Membrane.MP4.Muxer.CMAF` computes sample durations as dts deltas, which the
  per-session pts reset drives negative, and it emits no fresh init for an
  identical-SPS reconnect — so the ring would never learn the new session
  (P1-D11). A fresh ssrc per session is the RTP branch's own version of the
  same. The detect branch is not: the decoder's and inference's native state is
  the expensive half, and it is exactly what a reconnect must not cost — and
  since the tracker moved into the branch, so are the live tracks, which a
  boundary suspends rather than ends.

  A `{:session_ended, n}` from a gate is the parent's cue to link branch `n+1`
  at once — the gate is already queueing for it — and to drop branch `n`'s
  children a flush grace later, once the EOS that cut it has carried the
  muxer's held tail into the ring.

  No tee consumer takes its input on a `:manual` pad. That is the invariant the
  detect branch depends on: a manual input behind our push source arms
  membrane_core's toilet and is killed under exactly the overload it exists to
  survive, so the manual pads are internal to the branch — access units between
  `Cairn.Pipeline.Picker` and `Cairn.Pipeline.Decoder`, sampled RGB frames
  between the decoder and `Cairn.Pipeline.Inference` (D-C2's seam: frames as
  plain buffers, letterbox maths and motion verdict in metadata). The
  observations then flow as `Detections` buffers into
  `Cairn.Pipeline.ObservationStamper`, which clocks them and resolves the
  tracking context, through the generic `Membrane.MOTTracker` hosting the
  config-named core, and out at `Cairn.Pipeline.TrackSink`.

  The tee carries AU-aligned Annex-B H.264 — the TS demuxer's output on one
  ingest, the source's own SPS-derived format on the other (P1-D13); each
  branch owns its own format conversion (CMAF needs avc3 + per-AU keyframe
  metadata, which its parser stage adds).

  Tracked batches leave `Cairn.Pipeline.TrackSink` for `Cairn.Detect.Dispatch`
  directly; this process is on the reload path (a new policy, forwarded to both
  ends of the tracker) but not on the per-frame one.
  """

  use Membrane.Pipeline

  require Membrane.Logger

  alias Cairn.Motion

  alias Cairn.Pipeline.{
    BridgeSource,
    Decoder,
    EpochTagger,
    Inference,
    MotionGate,
    ObservationStamper,
    Picker,
    RingBufferSink,
    RTPOut,
    SessionCut,
    TrackSink
  }

  alias Membrane.Pad

  @cuts [:record_cut, :rtp_cut]

  @impl true
  def handle_init(_ctx, opts) do
    camera = Keyword.fetch!(opts, :camera)
    camera_id = camera.id
    owner = Keyword.fetch!(opts, :owner)
    detect = Keyword.get(opts, :detect)
    ingest = Keyword.get(opts, :ingest, :ffmpeg)

    spec =
      [
        ingest_spec(ingest, camera)
        |> child(:tagger, %EpochTagger{
          camera_id: camera_id,
          initial_reason: Keyword.get(opts, :initial_reason, :started)
        })
        |> child(:tee, Membrane.Tee.Parallel)
      ] ++
        Enum.map(@cuts, &(get_child(:tee) |> child(&1, %SessionCut{}))) ++
        Enum.flat_map(@cuts, &branch_spec(&1, camera_id, 0)) ++
        detect_spec(camera, detect)

    state = %{
      camera_id: camera_id,
      owner: owner,
      detecting?: detect != nil,
      sessions: Map.new(@cuts, &{&1, 0}),
      tracks: %{},
      # EOS is still propagating parser -> muxer -> ring sink when the gate
      # says the session ended, so the branch outlives its own cut by this
      # much or the muxer's held tail is dropped instead of recorded.
      flush_grace_ms: Keyword.get(opts, :flush_grace_ms, 500),
      # Branches scheduled for {:drop_branch, ...} but not yet dropped.
      pending_drops: 0
    }

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification({:session_ended, id}, cut, _ctx, state) when cut in @cuts do
    Process.send_after(self(), {:drop_branch, cut, id}, state.flush_grace_ms)
    pending = state.pending_drops + 1

    if pending > 2 do
      Membrane.Logger.warning(
        "#{state.camera_id}: #{pending} branches pending drop — a flapping camera outpacing flush_grace_ms"
      )
    end

    # Eagerly, not on a timer: the gate is queueing media for this pad already,
    # and every millisecond it waits is a millisecond missing from the ring.
    {[spec: branch_spec(cut, state.camera_id, id + 1)],
     %{state | sessions: Map.put(state.sessions, cut, id + 1), pending_drops: pending}}
  end

  # Ingest liveness the owner's watchdog and status need; it is the owner, not
  # this pipeline, that decides what a changed camera is worth.
  def handle_child_notification({:stream_connected, role, tracks}, :source, _ctx, state) do
    send(state.owner, {:stream_connected, role, tracks})
    {[], compare_tracks(state, role, tracks)}
  end

  def handle_child_notification({:stream_lost, _role} = notification, :source, _ctx, state) do
    send(state.owner, notification)
    {[], state}
  end

  def handle_child_notification({:stream_backoff, _role, _why} = note, :source, _ctx, state) do
    send(state.owner, note)
    {[], state}
  end

  def handle_child_notification({:stats, stats}, :track_sink, _ctx, state) do
    send(state.owner, {:stats, stats})
    {[], state}
  end

  # Detection turned off at runtime: the stamper stops feeding the tracker and
  # this is the only route from one to the other. Kept here rather than given
  # to the stamper as a pid so neither element knows the other exists.
  def handle_child_notification({:end_all, _reason} = notification, :stamper, _ctx, state) do
    {[notify_child: {:tracker, notification}], state}
  end

  def handle_child_notification(_notification, _child, _ctx, state), do: {[], state}

  # A reload's new policy, from `Cairn.PipelineOwner`. Both ends of the tracker
  # element hold one — the stamper resolves the tracking context from it, the
  # sink carries it to the camera's tracker — and a camera whose detect branch
  # was never built has nothing to tell.
  @impl true
  def handle_info({:policy, camera, policy}, _ctx, %{detecting?: true} = state) do
    {[
       notify_child: {:stamper, {:policy, camera, policy}},
       notify_child: {:track_sink, {:policy, camera, policy}}
     ], state}
  end

  def handle_info(:detect_stats, _ctx, %{detecting?: true} = state) do
    {[notify_child: {:track_sink, :stats}], state}
  end

  # A deliberate stop. The source's EOS travels the same path a session cut
  # does, so the muxer's tail reaches the ring before the owner terminates us.
  def handle_info(:flush, _ctx, state) do
    {[notify_child: {:source, :eos}], state}
  end

  def handle_info({:drop_branch, cut, id}, ctx, state) do
    {[remove_children: Enum.filter(branch_children(cut, id), &Map.has_key?(ctx.children, &1))],
     %{state | pending_drops: state.pending_drops - 1}}
  end

  def handle_info(_message, _ctx, state), do: {[], state}

  # Both ingests deliver the same thing to the tagger: AU-aligned Annex-B
  # H.264 with pts. The ffmpeg bridge wraps it in MPEG-TS because raw ES off a
  # pipe carries no timestamps (D-M8); the RTSP source element delivers whole
  # AUs with RTP pts natively — the exception D-M8 always recorded — and
  # synthesises the H.264 stream format from each session's own SPS, which is
  # why no parser stands between it and the tagger (P1-D13).
  defp ingest_spec(:ffmpeg, camera) do
    child(:source, %BridgeSource{camera_id: camera.id})
    |> child(:demuxer, %Membrane.MPEG.TS.Demuxer{})
    |> via_out(Pad.ref(:output, 1), options: [stream_category: :video])
  end

  defp ingest_spec(:rtsp, camera) do
    child(:source, %Membrane.RTSPDualStream.Source{stream_uri: camera.rtsp_url})
    |> via_out(Pad.ref(:output, :main))
  end

  defp branch_spec(:record_cut, camera_id, n) do
    [
      get_child(:record_cut)
      |> via_out(Pad.ref(:output, n))
      |> child({:cmaf_parser, n}, %Membrane.H264.Parser{
        output_alignment: :au,
        output_stream_structure: :avc3
      })
      |> via_in(Pad.ref(:input, :video))
      |> child({:cmaf, n}, %Membrane.MP4.Muxer.CMAF{
        # matches the classic path's `-frag_duration 2000000`
        segment_min_duration: Membrane.Time.seconds(2)
      })
      |> via_out(Pad.ref(:output, :video))
      |> child({:ring_sink, n}, %RingBufferSink{camera_id: camera_id})
    ]
  end

  defp branch_spec(:rtp_cut, camera_id, n) do
    [
      get_child(:rtp_cut)
      |> via_out(Pad.ref(:output, n))
      |> child({:rtp_out, n}, %RTPOut{camera_id: camera_id})
    ]
  end

  defp branch_children(:record_cut, n), do: [{:cmaf_parser, n}, {:cmaf, n}, {:ring_sink, n}]
  defp branch_children(:rtp_cut, n), do: [{:rtp_out, n}]

  # A changed control path or clock rate is absorbed inside the source (it
  # re-reads both from the SDP it just negotiated), so neither is identity. A
  # changed codec or track set is: the branches behind the tee are built around
  # it. Phase 1 only says so — deciding what to do about it is the owner's, and
  # nothing yet asks.
  defp compare_tracks(state, role, tracks) do
    identity = track_identity(tracks)

    case Map.get(state.tracks, role) do
      nil ->
        :ok

      ^identity ->
        :ok

      previous ->
        Membrane.Logger.warning(
          "#{state.camera_id}: #{role} stream came back with a different track identity: " <>
            "#{inspect(previous)} -> #{inspect(identity)}"
        )
    end

    %{state | tracks: Map.put(state.tracks, role, identity)}
  end

  defp track_identity(tracks) do
    Enum.map(tracks, fn track ->
      {Map.get(track, :type), Map.get(track, :fmtp), encoding(Map.get(track, :rtpmap))}
    end)
  end

  # SDP encoding names are case-insensitive and ExSDP preserves the camera's
  # spelling, so a camera that respells its own codec is not a change.
  defp encoding(%{encoding: encoding}), do: String.upcase(encoding)
  defp encoding(_absent), do: nil

  # No plugin configured is no detection, exactly as on the classic path.
  defp detect_spec(_camera, nil), do: []

  defp detect_spec(camera, detect) do
    stream_params = Keyword.get(detect, :stream_params, %{})
    gate = motion_gate(camera.id, detect, stream_params)
    policy = Keyword.fetch!(detect, :policy)

    [
      get_child(:tee)
      |> child(:picker, Picker)
      # One AU between the two, so the picker learns that the decoder is free
      # the moment it is, and no more than one is ever in flight.
      |> via_in(:input, target_queue_size: 1, min_demand_factor: 0.5)
      |> child(:decoder, %Decoder{
        camera_id: camera.id,
        stream_params: decoder_params(stream_params, gate)
      })
      |> maybe_gate(gate)
      # …and one sampled frame between decoder and inference, for the same
      # reason: inference demands only after `push_frame/5` returns.
      |> via_in(:input, target_queue_size: 1, min_demand_factor: 0.5)
      |> child(:infer, %Inference{
        session: {Cairn.Native.Host, Cairn.Native.Host},
        stream_id: camera.id,
        stream_params: stream_params
      })
      |> child(:stamper, %ObservationStamper{camera: camera, policy: policy})
      |> child(:tracker, %Membrane.MOTTracker{
        tracker: {Keyword.fetch!(detect, :tracker), []},
        # A camera cannot suspend more tracks than it was allowed to hold. Read
        # at birth and not per batch, unlike the live cap in the context: this
        # is an element option, so a reload that raises `max_live_tracks` does
        # not raise this one until the camera's next pipeline.
        max_suspended: policy.max_live_tracks
      })
      |> child(:track_sink, %TrackSink{camera: camera, policy: policy})
    ]
  end

  # The Nx measurement (D-C3): a configured gate becomes an element between
  # decoder and inference, and the decoder is told nothing about motion — the
  # verdict in the buffer metadata comes from `Cairn.Pipeline.MotionGate`
  # instead of from the decode NIF, behind the same contract. A bad
  # motion_json raises here, at pipeline build, where the operator reads a
  # config error rather than a per-frame one.
  defp motion_gate(camera_id, detect, stream_params) do
    case Motion.Config.resolve_json(Map.get(stream_params, :motion_json)) do
      {:ok, nil} ->
        nil

      {:ok, config} ->
        # No default: an enabled gate with an unknown sample rate would size
        # its calibration window silently wrong.
        %MotionGate{config: config, sample_fps: Keyword.fetch!(detect, :sample_fps)}

      {:error, message} ->
        raise ArgumentError, "camera #{camera_id}: motion_json: #{message}"
    end
  end

  # `Cairn.Pipeline.Inference` keeps the FULL stream params — the gate
  # *policy* (linger/epoch bypass/re-verify) lives with the model session and
  # still reads these knobs; only the measurement moved.
  defp decoder_params(stream_params, nil), do: stream_params
  defp decoder_params(stream_params, _gate), do: Map.put(stream_params, :motion_json, nil)

  defp maybe_gate(link, nil), do: link

  defp maybe_gate(link, %MotionGate{} = gate) do
    # The same one-frame seam as either side of it: the gate element passes
    # demand through one-for-one, so the decoder's latest-wins slot still
    # sees inference's real pace.
    link
    |> via_in(:input, target_queue_size: 1, min_demand_factor: 0.5)
    |> child(:motion_gate, gate)
  end
end
