defmodule Cairn.Pipeline.RtspSource do
  @moduledoc """
  Entry element of the membrane pipeline for RTSP-native ingest
  (`ingest: rtsp`): pushes H.264 access units received from the camera's
  `Cairn.FFmpegPort` downstream, exactly as `Cairn.Pipeline.BridgeSource`
  pushes MPEG-TS bytes for the ffmpeg bridge.

  The RTSP client (the `rtsp` library's session, with its socket, keepalive
  and depayloaders) and the reconnect/backoff policy stay in the port
  process, outside the pipeline — the same rule `BridgeSource` states: a
  pipeline crash must not take the camera's backoff state with it, and a
  dead camera is a normal long-lived state that must not burn supervisor
  restart intensity. This element only announces itself to the port owner
  (`{:rtsp_source_ready, epoch, pid}`) once it may emit buffers, then
  relays `{:rtsp_sample, payload, pts_ns}` messages as buffers.

  What arrives is already a whole Annex-B access unit with SPS/PPS
  prepended to keyframes (the library's depayloader guarantees it) and a
  pts the port has rescaled from the track's RTP clock to nanoseconds — so
  the output is `Membrane.RemoteStream` for `Membrane.H264.Parser` to
  turn into a proper `%Membrane.H264{alignment: :au}` stream. Unlike the
  bridge path there is no container: RTSP carries pts natively, which is
  the exception D-M8's MPEG-TS reasoning always recorded.
  """

  use Membrane.Source

  def_options(
    owner: [
      spec: pid(),
      description: "The camera's FFmpegPort, which streams `{:rtsp_sample, ...}` to us"
    ],
    session: [
      spec: Cairn.ULID.t(),
      description:
        "The stream epoch this pipeline belongs to, echoed in the ready " <>
          "handshake so a stale element outliving a force-kill cannot claim " <>
          "the successor session's samples"
    ]
  )

  def_output_pad(:output,
    accepted_format: %Membrane.RemoteStream{type: :packetized, content_format: Membrane.H264},
    flow_control: :push
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{owner: opts.owner, session: opts.session}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    send(state.owner, {:rtsp_source_ready, state.session, self()})

    {[
       stream_format:
         {:output, %Membrane.RemoteStream{type: :packetized, content_format: Membrane.H264}}
     ], state}
  end

  @impl true
  def handle_info({:rtsp_sample, payload, pts_ns}, _ctx, state)
      when is_binary(payload) and is_integer(pts_ns) do
    {[buffer: {:output, %Membrane.Buffer{payload: payload, pts: pts_ns}}], state}
  end

  # The session ended: everything it delivered is already in our mailbox
  # ahead of this message, so an end_of_stream lets the CMAF muxer flush its
  # held final segment into the ring instead of dropping up to 2 s of
  # recording on every session end — the same tail-flush contract as
  # `BridgeSource`'s :ts_eos.
  def handle_info(:rtsp_eos, ctx, state) do
    if ctx.pads.output.end_of_stream? do
      {[], state}
    else
      {[end_of_stream: :output], state}
    end
  end

  def handle_info(_msg, _ctx, state), do: {[], state}
end
