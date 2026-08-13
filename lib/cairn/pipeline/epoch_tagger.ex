defmodule Cairn.Pipeline.EpochTagger do
  @moduledoc """
  Mints one stream's epoch from the stream itself and makes it in-band: the
  first buffer of each session carries a fresh epoch, announced immediately
  ahead of it by a `Cairn.Pipeline.EpochChange` event and stamped into
  `metadata[:stream_epoch]` of every buffer of that session.

  One tagger per source pad, minting under that pad's `role:` — a camera with
  a substream has two, and their sessions boundary independently.

  Minting at production time rather than in the process that owns the pipeline
  is what makes the tag correct by construction (D8): the elements that survive
  a session boundary can still be draining the previous session's buffers, so an
  epoch applied where they are *consumed* mis-tags whatever is in flight.

  The mint waits for a buffer rather than firing on the `StreamClosed` ahead of
  it, because a source that never reconnects would otherwise announce an epoch
  nothing ever streams under — and consumers end their tracks on the
  announcement. `Membrane.Event.Discontinuity` mints nothing at all: RTP loss
  under a live session is still that session.

  `:camera_stopped` is not this element's to mint. A deliberate stop belongs to
  whoever owns the pipeline, which is what outlives it.

  Each session's stream format is also reported to the parent as
  `{:stream_format, role, format}` — this is the only element that sits on
  every ingest path and knows which of the camera's streams it is on, and a
  pipeline cannot read its children's pad formats. `Cairn.Pipeline.Camera`
  compares the two roles' geometry with it.
  """

  use Membrane.Filter

  alias Cairn.Pipeline.EpochChange
  alias Cairn.StreamEpochs
  alias Membrane.RTSPDualStream.Event.StreamClosed

  def_input_pad(:input, accepted_format: _any, flow_control: :auto)

  # Whatever the ingest carries: H264 from the RTSP source, or whatever the
  # MPEG-TS demuxer emits on the bridge path.
  def_output_pad(:output, accepted_format: _any, flow_control: :auto)

  def_options(
    camera_id: [spec: String.t()],
    role: [
      spec: StreamEpochs.role(),
      default: :main,
      description: "Which of the camera's streams this tagger sits behind"
    ],
    initial_reason: [
      spec: StreamEpochs.reason(),
      default: :started,
      description: "Reason carried by the first mint; a watchdog rebuild passes :stall_bounce"
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       stream: {opts.camera_id, opts.role},
       role: opts.role,
       epoch: nil,
       pending_reason: opts.initial_reason
     }}
  end

  # Reported whatever it carries: what counts as usable geometry is the
  # parent's judgement, and the MPEG-TS demuxer's format has none to offer.
  @impl true
  def handle_stream_format(:input, format, ctx, state) do
    {actions, state} = super(:input, format, ctx, state)
    {actions ++ [notify_parent: {:stream_format, state.role, format}], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, %{pending_reason: nil} = state) do
    {[buffer: {:output, stamp(buffer, state.epoch)}], state}
  end

  def handle_buffer(:input, buffer, _ctx, %{pending_reason: reason} = state) do
    # `new_epoch/2` broadcasts, which is how `Cairn.CameraTracker` learns of the
    # boundary; nothing else here signals it.
    epoch = StreamEpochs.new_epoch(state.stream, reason)

    # Event before buffer: a consumer that sees the buffer first has already
    # attributed it to the epoch it is leaving.
    {[
       event: {:output, %EpochChange{epoch: epoch, reason: reason}},
       buffer: {:output, stamp(buffer, epoch)}
     ], %{state | epoch: epoch, pending_reason: nil}}
  end

  @impl true
  def handle_event(:input, %StreamClosed{reason: reason} = event, ctx, state) do
    {actions, state} = super(:input, event, ctx, state)
    {actions, %{state | pending_reason: mint_reason(reason)}}
  end

  # Overriding the callback replaces the filter's forwarding default outright,
  # so everything else has to be handed back to it explicitly.
  def handle_event(pad, event, ctx, state), do: super(pad, event, ctx, state)

  # The event's vocabulary is "how the session ended", `StreamEpochs`' is "why
  # the next one exists" — the same fact from either side of the boundary, and
  # only `:closed` needs the translation.
  defp mint_reason(:closed), do: :source_lost
  defp mint_reason(reason), do: reason

  defp stamp(buffer, epoch) do
    %{buffer | metadata: Map.put(buffer.metadata, :stream_epoch, epoch)}
  end
end
