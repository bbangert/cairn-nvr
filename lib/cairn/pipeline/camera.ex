defmodule Cairn.Pipeline.Camera do
  @moduledoc """
  Per-session membrane pipeline for one camera:

      BridgeSource ─ TS demux ─ tee ─┬─ parser(avc3) ─ CMAF ─ RingBufferSink
                                     └─ RTPOut (in-process WebRTC hub feed)

  Started by `Cairn.FFmpegPort` alongside each ffmpeg spawn and torn down
  with it — the TS demuxer's state is only valid for one continuous ffmpeg
  session, so the pipeline shares the session's lifetime and its epoch. The
  detect branch joins the tee in port plan phase 3.

  The tee carries AU-aligned Annex-B H.264 as the TS demuxer emits it; each
  branch owns its own format conversion (CMAF needs avc3 + per-AU keyframe
  metadata, which its parser stage adds).
  """

  use Membrane.Pipeline

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

    {[spec: spec], %{camera_id: camera_id}}
  end
end
