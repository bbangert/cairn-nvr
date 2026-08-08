defmodule Cairn.Pipeline.RTPOut.Sink do
  @moduledoc false
  # Terminal sink of the RTP branch (a child of `Cairn.Pipeline.RTPOut`). Builds
  # each ExRTP.Packet and pushes it to the hub, owning the RTP header state the
  # payloader leaves to the caller: a per-AU 90 kHz timestamp derived from the
  # buffer pts (all NAL units of one AU share a pts, so they share a timestamp —
  # exactly the boundary the hub's GOP reset keys on), a 16-bit wrapping sequence
  # counter, and one random 32-bit ssrc per element start. Payload type 96
  # (dynamic H264); marker comes from the payloader's per-buffer AU-end metadata.
  use Membrane.Sink

  alias Membrane.{H264, RTP}

  @payload_type 96
  @seq_wrap 0x1_0000
  @ts_wrap 0x1_0000_0000
  @rtp_clock_hz 90_000

  def_options camera_id: [spec: String.t()]

  def_input_pad :input, accepted_format: %RTP{payload_format: H264}

  @impl true
  def handle_init(_ctx, opts) do
    # ssrc identifies this stream instance to viewers; a fresh restart is a new
    # RTP stream, so seed it once here rather than per packet.
    ssrc = :rand.uniform(@ts_wrap) - 1
    {[], %{camera_id: opts.camera_id, seq: 0, ssrc: ssrc}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    timestamp = rem(div(buffer.pts * @rtp_clock_hz, Membrane.Time.second()), @ts_wrap)
    marker = match?(%{rtp: %{marker: true}}, buffer.metadata)

    packet =
      ExRTP.Packet.new(buffer.payload,
        payload_type: @payload_type,
        sequence_number: state.seq,
        timestamp: timestamp,
        ssrc: state.ssrc,
        marker: marker
      )

    Cairn.RTPHub.push_packet(state.camera_id, packet)

    {[], %{state | seq: rem(state.seq + 1, @seq_wrap)}}
  end
end

defmodule Cairn.Pipeline.RTPOut do
  @moduledoc """
  Membrane RTP output branch: payloads H.264 access units into RTP packets and
  feeds them to the per-camera `Cairn.RTPHub` in-process (no UDP socket),
  matching what ffmpeg's RTP mux hands the classic hub.

  A Bin rather than a plain sink because the reused RFC 6184 payloader
  (`Membrane.RTP.H264.Payloader`) is a separate element: the tee feeds
  AU-aligned annexb H264, so the branch re-parses to NAL-unit alignment (the
  payloader's only accepted input), payloads, then `Cairn.Pipeline.RTPOut.Sink`
  turns each RTP payload into an `ExRTP.Packet` and calls
  `Cairn.RTPHub.push_packet/2`.
  """

  use Membrane.Bin

  alias Membrane.H264

  def_options camera_id: [spec: String.t()]

  # The tee emits AU-aligned annexb H264 with parameter sets in-band (classic
  # parity); the child parser splits those AUs into the NAL units the payloader
  # requires, carrying the in-band SPS/PPS through so browsers still get them.
  def_input_pad :input, accepted_format: %H264{alignment: :au}

  @impl true
  def handle_init(_ctx, opts) do
    spec =
      bin_input()
      |> child(:parser, %Membrane.H264.Parser{
        output_alignment: :nalu,
        output_stream_structure: :annexb
      })
      |> child(:payloader, %Membrane.RTP.H264.Payloader{})
      |> child(:sink, %Cairn.Pipeline.RTPOut.Sink{camera_id: opts.camera_id})

    {[spec: spec], %{}}
  end
end
