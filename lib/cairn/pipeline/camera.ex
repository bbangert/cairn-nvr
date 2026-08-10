defmodule Cairn.Pipeline.Camera do
  @moduledoc """
  Per-session membrane pipeline for one camera:

      BridgeSource ─ TS demux ─ tee ─┬─ parser(avc3) ─ CMAF ─ RingBufferSink
                                     ├─ RTPOut (in-process WebRTC hub feed)
                                     └─ Picker ─(manual)─ Decoder ─(manual)─ InferSink

  Started by `Cairn.FFmpegPort` alongside each ffmpeg spawn and torn down
  with it — the TS demuxer's state is only valid for one continuous ffmpeg
  session, so the pipeline shares the session's lifetime and its epoch.

  No tee consumer takes its input on a `:manual` pad. That is the invariant the
  detect branch depends on: a manual input behind our push source arms
  membrane_core's toilet and is killed under exactly the overload it exists to
  survive, so the manual pads are internal to the branch — access units between
  `Cairn.Pipeline.Picker` and `Cairn.Pipeline.Decoder`, sampled RGB frames
  between the decoder and `Cairn.Pipeline.InferSink` (D-C2's seam: frames as
  plain buffers, letterbox maths and motion verdict in metadata).

  The tee carries AU-aligned Annex-B H.264 as the TS demuxer emits it; each
  branch owns its own format conversion (CMAF needs avc3 + per-AU keyframe
  metadata, which its parser stage adds).

  Detections leave the sink for `Cairn.Detect.Dispatch` directly; this process
  is on the reload path (a new policy, forwarded to the sink) but not on the
  per-frame one.
  """

  use Membrane.Pipeline

  alias Cairn.Pipeline.{Decoder, InferSink, Picker}
  alias Membrane.Pad

  @impl true
  def handle_init(_ctx, opts) do
    camera = Keyword.fetch!(opts, :camera)
    camera_id = camera.id
    epoch = Keyword.fetch!(opts, :epoch)
    owner = Keyword.fetch!(opts, :owner)
    detect = Keyword.get(opts, :detect)

    spec = [
      child(:source, %Cairn.Pipeline.BridgeSource{owner: owner, session: epoch})
      |> child(:demuxer, %Membrane.MPEG.TS.Demuxer{})
      |> via_out(Pad.ref(:output, 1), options: [stream_category: :video])
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

  # A reload's new policy, from `Cairn.FFmpegPort`. Only the sink holds one, so
  # a camera whose detect branch was never built has nothing to tell.
  @impl true
  def handle_info({:policy, camera, policy}, _ctx, %{detecting?: true} = state) do
    {[notify_child: {:infer, {:policy, camera, policy}}], state}
  end

  def handle_info(_message, _ctx, state), do: {[], state}

  # No plugin configured is no detection, exactly as on the classic path.
  defp detect_spec(_camera, _epoch, nil), do: []

  defp detect_spec(camera, epoch, detect) do
    stream_params = Keyword.get(detect, :stream_params, %{})

    [
      get_child(:tee)
      |> child(:picker, Picker)
      # One AU between the two, so the picker learns that the decoder is free
      # the moment it is, and no more than one is ever in flight.
      |> via_in(:input, target_queue_size: 1, min_demand_factor: 0.5)
      |> child(:decoder, %Decoder{camera_id: camera.id, stream_params: stream_params})
      # …and one sampled frame between decoder and sink, for the same reason:
      # the sink demands only after `push_frame/5` returns.
      |> via_in(:input, target_queue_size: 1, min_demand_factor: 0.5)
      |> child(:infer, %InferSink{
        camera: camera,
        policy: Keyword.fetch!(detect, :policy),
        epoch: epoch,
        stream_params: stream_params
      })
    ]
  end
end
