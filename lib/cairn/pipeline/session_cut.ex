defmodule Cairn.Pipeline.SessionCut do
  @moduledoc """
  The seam between the long-lived half of a camera's pipeline and its
  per-session half: input from the tee, one on-request output pad per session
  (`Pad.ref(:output, n)`, `n` the parent's session counter, opaque here).

  A `StreamClosed` becomes `end_of_stream` on the session's pad. EOS is what
  flushes the CMAF muxer's held sub-min-duration tail into the ring — the same
  contract teardown gives today — and the branch behind it has to die anyway:
  that muxer survives neither the per-session pts reset (sample durations are
  dts deltas, so the splice sample's goes negative) nor an identical-SPS
  reconnect (no fresh init, so the ring never learns the new session).

  Between the cut and the parent linking the next branch, this element is the
  only thing holding the stream. Pad linkage is the entire handshake: nothing
  is asked of the parent, nothing waited on, and a session that dies before its
  branch is ever linked simply takes its queue with it.
  """

  use Membrane.Filter

  import Bitwise, only: [band: 2]

  require Membrane.Logger

  alias Membrane.Buffer
  alias Membrane.Pad
  alias Membrane.RTSPDualStream.Event.StreamClosed

  def_input_pad(:input, accepted_format: _any, flow_control: :auto)

  def_output_pad(:output,
    availability: :on_request,
    accepted_format: _any,
    flow_control: :auto
  )

  def_options(
    queue_max_bytes: [
      spec: pos_integer(),
      default: 8 * 1024 * 1024,
      description: "Cap on media held between a session's cut and its successor's branch"
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       active: nil,
       format: nil,
       # arrival order, reversed
       queue: [],
       queued_bytes: 0,
       dropped_bytes: 0,
       logged_drop?: false,
       # true from the start for the same reason as after a cut: whatever
       # branch is linked first must still be handed a decodable stream
       awaiting_keyframe?: true,
       queue_max_bytes: opts.queue_max_bytes
     }}
  end

  # No playback guard on the flush: buffers and stream formats reach an element
  # only while it is playing, so a pad linked before that can only ever find
  # both empty — and the actions below would be refused.
  @impl true
  def handle_pad_added(pad, _ctx, state) do
    queue = Enum.reverse(state.queue)

    # A fresh branch has to learn the format from us: on the bridge path the
    # long-lived demuxer emits one per pipeline, not one per session.
    lead =
      if state.format != nil and not format_first?(queue),
        do: [stream_format: {pad, state.format}],
        else: []

    {lead ++ flush(queue, pad),
     %{
       state
       | active: pad,
         queue: [],
         queued_bytes: 0,
         dropped_bytes: 0,
         logged_drop?: false
         # awaiting_keyframe? deliberately not reset here: it is queue-scoped,
         # not pad-scoped — every cut re-arms it, and it goes unread while a
         # pad is active.
     }}
  end

  # Removal is normally the parent dropping a drained branch, whose pad this
  # element already EOS'd and forgot. An *active* pad going is defensive only,
  # and puts the stream back where a cut would: queueing behind an IDR.
  @impl true
  def handle_pad_removed(pad, _ctx, %{active: pad} = state) do
    {[], %{state | active: nil, awaiting_keyframe?: true}}
  end

  def handle_pad_removed(_pad, _ctx, state), do: {[], state}

  @impl true
  def handle_stream_format(:input, format, _ctx, %{active: nil} = state) do
    {[], enqueue(%{state | format: format}, {:stream_format, format})}
  end

  def handle_stream_format(:input, format, _ctx, state) do
    {[stream_format: {state.active, format}], %{state | format: format}}
  end

  @impl true
  def handle_event(:input, %StreamClosed{}, _ctx, %{active: nil} = state) do
    # A session that died before its branch was linked: nothing will ever
    # consume what it left, and the next session must not inherit it. It counts
    # as dropped because it is — the stats are what an operator reads to see
    # that a flapping camera is losing recording.
    {[],
     %{
       state
       | queue: [],
         queued_bytes: 0,
         dropped_bytes: state.dropped_bytes + state.queued_bytes,
         awaiting_keyframe?: true
     }}
  end

  def handle_event(:input, %StreamClosed{}, _ctx, state) do
    Pad.ref(:output, id) = state.active

    # The EOS is the cut, and nothing may follow it on this pad — so the
    # StreamClosed itself stops here.
    {[end_of_stream: state.active, notify_parent: {:session_ended, id}],
     %{state | active: nil, awaiting_keyframe?: true}}
  end

  def handle_event(:input, event, _ctx, %{active: nil} = state) do
    # Never dropped by the keyframe gate: an EpochChange landing between
    # sessions has to reach the branch that the epoch names.
    {[], enqueue(state, {:event, event})}
  end

  def handle_event(:input, event, _ctx, state) do
    {[event: {state.active, event}], state}
  end

  # Upstream events from a branch. Overriding the callback replaces the filter's
  # forwarding default outright, so they have to be handed back to it.
  def handle_event(pad, event, ctx, state), do: super(pad, event, ctx, state)

  @impl true
  def handle_buffer(:input, buffer, _ctx, %{active: nil} = state) do
    cond do
      state.awaiting_keyframe? and not keyframe?(buffer) ->
        # The bridge path's only gate against the one stale pre-cut access unit
        # the long-lived TS demuxer can flush behind a StreamClosed.
        {[], drop(state, buffer)}

      state.queued_bytes + byte_size(buffer.payload) > state.queue_max_bytes ->
        {[], drop(state, buffer)}

      true ->
        {[],
         enqueue(
           %{
             state
             | awaiting_keyframe?: false,
               queued_bytes: state.queued_bytes + byte_size(buffer.payload)
           },
           {:buffer, buffer}
         )}
    end
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    {[buffer: {state.active, buffer}], state}
  end

  # A deliberate stop, not a session boundary: the muxer's tail still has to
  # reach the ring.
  @impl true
  def handle_end_of_stream(:input, _ctx, %{active: nil} = state), do: {[], state}

  def handle_end_of_stream(:input, _ctx, state) do
    {[end_of_stream: state.active], %{state | active: nil}}
  end

  @impl true
  def handle_parent_notification(:stats, _ctx, state) do
    stats = %{dropped_bytes: state.dropped_bytes, queued_bytes: state.queued_bytes}
    {[notify_parent: {:stats, stats}], state}
  end

  defp enqueue(state, item), do: %{state | queue: [item | state.queue]}

  defp flush(queue, pad) do
    Enum.map(queue, fn
      {:buffer, buffer} -> {:buffer, {pad, buffer}}
      {:event, event} -> {:event, {pad, event}}
      {:stream_format, format} -> {:stream_format, {pad, format}}
    end)
  end

  defp format_first?([{:stream_format, _format} | _rest]), do: true
  defp format_first?([{:buffer, _buffer} | _rest]), do: false
  defp format_first?([_event | rest]), do: format_first?(rest)
  defp format_first?([]), do: false

  # One line per queue period, not per buffer: an unlinked branch drops at the
  # camera's full bitrate. The flag rather than a zero `dropped_bytes`, which a
  # discarded queue also moves.
  defp drop(%{logged_drop?: false} = state, buffer) do
    Membrane.Logger.warning(
      "no session branch linked: dropping media after #{state.queued_bytes} queued bytes"
    )

    drop(%{state | logged_drop?: true}, buffer)
  end

  defp drop(state, buffer) do
    %{state | dropped_bytes: state.dropped_bytes + byte_size(buffer.payload)}
  end

  defp keyframe?(%Buffer{metadata: %{keyframe?: keyframe?}}) when is_boolean(keyframe?),
    do: keyframe?

  defp keyframe?(%Buffer{payload: payload}), do: vcl_type(payload) == 5

  # `Cairn.Pipeline.Picker`'s walk, for the ingest that carries no keyframe
  # metadata: the first VCL NAL's type is the whole answer, and it is a few NALs
  # in. Shared with the picker only by copy — one module for fifteen lines would
  # couple two branches that have nothing else in common.
  defp vcl_type(payload) do
    with {at, len} <- :binary.match(payload, <<0, 0, 1>>),
         skip = at + len,
         <<_::binary-size(^skip), header, rest::binary>> <- payload do
      nal_type(band(header, 0x1F), rest)
    else
      _nomatch_or_truncated -> nil
    end
  end

  # 5 is an IDR slice, 1..4 the non-IDR ones; anything else (SPS, PPS, AUD, SEI)
  # precedes the picture and says nothing about it.
  defp nal_type(type, _rest) when type in 1..5, do: type
  defp nal_type(_parameter_or_delimiter, rest), do: vcl_type(rest)
end
