defmodule Cairn.Pipeline.Picker do
  @moduledoc """
  The detect branch's backpressure: every access unit the tee carries is handed
  on, at full frame rate, until the sink has no demand for one.

  `:input` is `:auto`, `:output` is `:manual`. The asymmetry is the whole
  mechanism: the tee side drains at line rate (auto behind our push source
  resolves to push, so no toilet is armed and this branch can never throttle
  recording), while the sink side hands out one AU per demand. What does not fit
  is destroyed rather than queued — one slot — so memory is O(1). The slot keeps
  the *older* AU of the two, against the usual instinct: a decoder can only use
  the next one in sequence, and one AU of staleness is a frame period.
  A keyframe is the exception and displaces whatever is waiting.

  The rate lives in the crate, after `receive_frame` and before `to_tensor`
  (`cairn-native`'s `Stream::push_au`). Thinning here instead would admit only
  keyframe-headed AUs, since a stateful decoder needs its references — capping
  detection at the GOP rate, which on this fleet is 0.21-0.50/s against a
  `sample_fps` of 5.

  What is forwarded is always decodable: a keyframe always, and a non-keyframe
  only while nothing has been dropped since the last one forwarded. After a drop
  the branch waits for the next IDR. ffmpeg would otherwise conceal the gap
  silently — no error, no flag on the frame — and a concealed frame is worth less
  than no frame: person recall falls to 0.42/0.30 by four frames in and one
  measured camera reported more phantom people than real ones
  (`research/concealment-decode.md`). Nothing between the hole and the IDR is
  worth decoding either, since an IDR resynchronises the decoder on its own.

  So a source that never sends an IDR detects nothing after its first drop. That
  is a dependency the recording branch already has — `Membrane.MP4.Muxer.CMAF`
  and `Cairn.Pipeline.RingBufferSink` both cut on keyframes — so such a source
  fails visibly there first.
  """

  use Membrane.Filter

  import Bitwise, only: [band: 2]

  alias Membrane.Buffer

  def_input_pad(:input, accepted_format: %Membrane.H264{alignment: :au}, flow_control: :auto)

  def_output_pad(:output, accepted_format: %Membrane.H264{alignment: :au}, flow_control: :manual)

  @impl true
  def handle_init(_ctx, _opts) do
    # `expecting_keyframe?` starts true because the crate's decoder starts empty:
    # the first AU it can make a picture from is an IDR either way.
    {[],
     %{
       pending: nil,
       pending_keyframe?: false,
       expecting_keyframe?: true,
       demand: 0,
       dropped: 0,
       emitted: 0
     }}
  end

  @impl true
  def handle_buffer(:input, %Buffer{pts: pts} = buffer, _ctx, state) when is_integer(pts) do
    maybe_send(admit(state, buffer))
  end

  # No pts is no timestamp to date a detection with, so it is not a candidate.
  def handle_buffer(:input, _buffer, _ctx, state), do: {[], drop(state)}

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    maybe_send(%{state | demand: state.demand + size})
  end

  @impl true
  def handle_parent_notification(:stats, _ctx, state) do
    {[notify_parent: {:stats, %{dropped: state.dropped, emitted: state.emitted}}], state}
  end

  defp admit(state, buffer) do
    cond do
      # Whatever it displaces, and whatever came before it, an IDR needs neither.
      keyframe?(buffer.payload) -> keep(state, buffer, true)
      state.expecting_keyframe? -> drop(state)
      state.pending == nil -> keep(state, buffer, false)
      # The slot is full, so this AU is lost — and with it every AU after it,
      # because the hole is between what is waiting and whatever comes next.
      true -> drop(state)
    end
  end

  defp keep(%{pending: nil} = state, buffer, keyframe?),
    do: %{state | pending: buffer, pending_keyframe?: keyframe?, expecting_keyframe?: false}

  defp keep(state, buffer, keyframe?),
    do: keep(%{drop(state) | pending: nil}, buffer, keyframe?)

  defp drop(state), do: %{state | dropped: state.dropped + 1, expecting_keyframe?: true}

  # The rendezvous: whichever of demand and a pending AU arrives second emits, so
  # the element is edge-triggered from both sides and never polls. Clearing the
  # slot here rather than on the way out is what keeps unmet demand across a
  # downstream failure.
  defp maybe_send(%{pending: %Buffer{} = buffer, demand: demand} = state) when demand > 0 do
    state = %{
      state
      | pending: nil,
        pending_keyframe?: false,
        demand: demand - 1,
        emitted: state.emitted + 1
    }

    {[buffer: {:output, buffer}], state}
  end

  defp maybe_send(state), do: {[], state}

  # The tee carries the TS demuxer's Annex-B AUs, which have no keyframe
  # metadata — the parser that adds it sits on the CMAF branch, past the tee. The
  # first VCL NAL's type is the whole answer and it is a few NALs in, so this
  # stops there rather than walking the AU.
  defp keyframe?(payload), do: vcl_type(payload) == 5

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
