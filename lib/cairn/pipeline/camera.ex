defmodule Cairn.Pipeline.Camera do
  @moduledoc """
  Per-session membrane pipeline for one camera. The ingest stage differs by
  `ingest:`; everything from the tee on is identical:

      ingest: ffmpeg   BridgeSource ─ TS demux ──┐
      ingest: rtsp     RtspSource ─ parser(au) ──┤
                                                 │
       tee ─┬─ parser(avc3) ─ CMAF ─ RingBufferSink
            ├─ RTPOut (in-process WebRTC hub feed)
            └─ Picker ─(manual)─ Decoder ─(manual)─ Inference ─ DetectSink

  Started by `Cairn.FFmpegPort` alongside each ingest session — an ffmpeg
  spawn or an RTSP client — and torn down with it: the TS demuxer's state
  (and equally an RTSP session's sample stream) is only valid for one
  continuous session, so the pipeline shares the session's lifetime and its
  epoch. The ffmpeg bridge wraps the stream in MPEG-TS because raw ES off a
  pipe carries no timestamps (D-M8); the RTSP client delivers access units
  with RTP pts natively, so its path is a parser instead of a demuxer.

  No tee consumer takes its input on a `:manual` pad. That is the invariant the
  detect branch depends on: a manual input behind our push source arms
  membrane_core's toilet and is killed under exactly the overload it exists to
  survive, so the manual pads are internal to the branch — access units between
  `Cairn.Pipeline.Picker` and `Cairn.Pipeline.Decoder`, sampled RGB frames
  between the decoder and `Cairn.Pipeline.Inference` (D-C2's seam: frames as
  plain buffers, letterbox maths and motion verdict in metadata). The
  observations then flow as `Detections` buffers into
  `Cairn.Pipeline.DetectSink`, the cairn-side half that dispatches them.

  The tee carries AU-aligned Annex-B H.264 as the TS demuxer emits it; each
  branch owns its own format conversion (CMAF needs avc3 + per-AU keyframe
  metadata, which its parser stage adds).

  Detections leave `Cairn.Pipeline.DetectSink` for `Cairn.Detect.Dispatch`
  directly; this process is on the reload path (a new policy, forwarded to
  that sink) but not on the per-frame one.
  """

  use Membrane.Pipeline

  alias Cairn.Motion
  alias Cairn.Pipeline.{Decoder, DetectSink, Inference, MotionGate, Picker}
  alias Membrane.Pad

  @impl true
  def handle_init(_ctx, opts) do
    camera = Keyword.fetch!(opts, :camera)
    camera_id = camera.id
    epoch = Keyword.fetch!(opts, :epoch)
    owner = Keyword.fetch!(opts, :owner)
    detect = Keyword.get(opts, :detect)
    ingest = Keyword.get(opts, :ingest, :ffmpeg)

    spec = [
      ingest_spec(ingest, owner, epoch)
      |> child(:tee, Membrane.Tee.Parallel),
      get_child(:tee)
      |> child(:cmaf_parser, %Membrane.H264.Parser{
        output_alignment: :au,
        output_stream_structure: :avc3
      })
      |> via_in(Pad.ref(:input, :video))
      |> child(:cmaf, %Membrane.MP4.Muxer.CMAF{
        # matches the classic path's `-frag_duration 2000000`
        segment_min_duration: Membrane.Time.seconds(2)
      })
      |> via_out(Pad.ref(:output, :video))
      |> child(:ring_sink, %Cairn.Pipeline.RingBufferSink{camera_id: camera_id, epoch: epoch}),
      get_child(:tee)
      |> child(:rtp_out, %Cairn.Pipeline.RTPOut{camera_id: camera_id})
    ]

    {[spec: spec ++ detect_spec(camera, epoch, detect)],
     %{camera_id: camera_id, detecting?: detect != nil}}
  end

  @impl true
  def handle_child_notification(_notification, _child, _ctx, state), do: {[], state}

  # A reload's new policy, from `Cairn.FFmpegPort`. Only the detect sink holds
  # one, so a camera whose detect branch was never built has nothing to tell.
  @impl true
  def handle_info({:policy, camera, policy}, _ctx, %{detecting?: true} = state) do
    {[notify_child: {:detect, {:policy, camera, policy}}], state}
  end

  def handle_info(_message, _ctx, state), do: {[], state}

  # Both ingests deliver the same thing to the tee: AU-aligned Annex-B H.264
  # with pts. The ffmpeg bridge wraps it in MPEG-TS because raw ES off a pipe
  # carries no timestamps (D-M8); the RTSP client delivers whole AUs with RTP
  # pts natively — the exception D-M8 always recorded — so its path is a
  # parser instead of a demuxer.
  defp ingest_spec(:ffmpeg, owner, epoch) do
    child(:source, %Cairn.Pipeline.BridgeSource{owner: owner, session: epoch})
    |> child(:demuxer, %Membrane.MPEG.TS.Demuxer{})
    |> via_out(Pad.ref(:output, 1), options: [stream_category: :video])
  end

  defp ingest_spec(:rtsp, owner, epoch) do
    child(:source, %Cairn.Pipeline.RtspSource{owner: owner, session: epoch})
    |> child(:ingest_parser, %Membrane.H264.Parser{
      output_alignment: :au,
      # Explicit, matching what the demuxer path carries to the tee: the
      # cmaf branch re-parses to :avc3 itself, and the RTP branch wants
      # in-band parameter sets.
      output_stream_structure: :annexb
    })
  end

  # No plugin configured is no detection, exactly as on the classic path.
  defp detect_spec(_camera, _epoch, nil), do: []

  defp detect_spec(camera, epoch, detect) do
    stream_params = Keyword.get(detect, :stream_params, %{})
    gate = motion_gate(camera.id, detect, stream_params)

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
        stream_params: Map.put(stream_params, :stream_epoch, epoch)
      })
      |> child(:detect, %DetectSink{
        camera: camera,
        policy: Keyword.fetch!(detect, :policy),
        epoch: epoch
      })
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
