defmodule Cairn.Pipeline.Camera do
  @moduledoc """
  Per-session membrane pipeline for one camera:

      BridgeSource ─ TS demux ─ tee ─┬─ parser(avc3) ─ CMAF ─ RingBufferSink
                                     ├─ RTPOut (in-process WebRTC hub feed)
                                     └─ Picker ─(manual)─ InferSink

  Started by `Cairn.FFmpegPort` alongside each ffmpeg spawn and torn down
  with it — the TS demuxer's state is only valid for one continuous ffmpeg
  session, so the pipeline shares the session's lifetime and its epoch.

  No tee consumer takes its input on a `:manual` pad. That is the invariant the
  detect branch depends on: a manual input behind our push source arms
  membrane_core's toilet and is killed under exactly the overload it exists to
  survive, so the only manual pad off the tee is the internal one between
  `Cairn.Pipeline.Picker` and `Cairn.Pipeline.InferSink`.

  The tee carries AU-aligned Annex-B H.264 as the TS demuxer emits it; each
  branch owns its own format conversion (CMAF needs avc3 + per-AU keyframe
  metadata, which its parser stage adds).
  """

  use Membrane.Pipeline

  alias Cairn.Pipeline.{InferSink, Picker}
  alias Membrane.Pad

  @impl true
  def handle_init(_ctx, opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)
    epoch = Keyword.fetch!(opts, :epoch)
    owner = Keyword.fetch!(opts, :owner)

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

    {[spec: spec ++ detect_spec(camera_id, epoch, Keyword.get(opts, :detect))],
     %{camera_id: camera_id}}
  end

  # SEAM (port plan 3.2): the observations go to the tracker fork from here.
  @impl true
  def handle_child_notification({:observations, _camera_id, _observations}, :infer, _ctx, state) do
    {[], state}
  end

  def handle_child_notification(_notification, _child, _ctx, state), do: {[], state}

  # No plugin configured is no detection, exactly as on the classic path.
  defp detect_spec(_camera_id, _epoch, nil), do: []

  defp detect_spec(camera_id, epoch, detect) do
    [
      get_child(:tee)
      |> child(:picker, struct(Picker, Keyword.take(detect, [:sample_fps])))
      # One AU between the two, so the picker learns that the model is free the
      # moment it is, and no more than one is ever in flight.
      |> via_in(:input, target_queue_size: 1, min_demand_factor: 0.5)
      |> child(:infer, %InferSink{
        camera_id: camera_id,
        epoch: epoch,
        stream_params: Keyword.get(detect, :stream_params, %{})
      })
    ]
  end
end
