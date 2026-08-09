defmodule Cairn.Pipeline.Picker do
  @moduledoc """
  Chooses which encoded access units the detect branch pays for.

  `:input` is `:auto`, `:output` is `:manual`. The asymmetry is the whole
  mechanism: the tee side drains at line rate (auto behind our push source
  resolves to push, so no toilet is armed and this branch can never throttle
  recording), while the sink side hands out one AU per demand. What does not fit
  is destroyed rather than queued — one slot, keep-newest — so memory is O(1) and
  the AU that reaches the model is the freshest one.

  This is the branch's only rate gate: `cairn-native` spends at most one model
  pass per AU it is handed (its motion gate can still skip one) and thins nothing
  on the clock. A second clock gate downstream, at the same nominal interval,
  would leave the effective rate near half of it.

  Only a keyframe-headed AU is eligible, and there is deliberately no option to
  say otherwise: dropping mid-GOP would hand `cairn-native`'s stateful decoder a
  bitstream with holes, whose output is undefined until the next IDR.
  """

  use Membrane.Filter

  import Bitwise, only: [band: 2]

  def_input_pad(:input, accepted_format: %Membrane.H264{alignment: :au}, flow_control: :auto)

  def_output_pad(:output, accepted_format: %Membrane.H264{alignment: :au}, flow_control: :manual)

  def_options(
    sample_fps: [
      spec: 1..30,
      default: 5,
      description: "Ceiling on how often an AU is handed downstream, per `--sample-fps`"
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       interval_ms: ceil(1000 / opts.sample_fps),
       last_ms: nil,
       pending: nil,
       demand: 0,
       dropped: 0,
       emitted: 0
     }}
  end

  @impl true
  def handle_buffer(:input, %Membrane.Buffer{pts: pts} = buffer, _ctx, state)
      when is_integer(pts) do
    if due?(state) and keyframe?(buffer.payload) do
      # Overwrites unconditionally: whatever was waiting is now the stale one.
      maybe_send(%{state | pending: buffer, dropped: state.dropped + dropped(state.pending)})
    else
      {[], %{state | dropped: state.dropped + 1}}
    end
  end

  # No pts is no timestamp to date a detection with, so it is not a candidate.
  def handle_buffer(:input, _buffer, _ctx, state), do: {[], %{state | dropped: state.dropped + 1}}

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    maybe_send(%{state | demand: state.demand + size})
  end

  @impl true
  def handle_parent_notification(:stats, _ctx, state) do
    {[notify_parent: {:stats, %{dropped: state.dropped, emitted: state.emitted}}], state}
  end

  # The rendezvous: whichever of demand and eligibility arrives second emits, so
  # the element is edge-triggered from both sides and never polls. Clearing the
  # slot here rather than on the way out is what keeps unmet demand across a
  # downstream failure.
  defp maybe_send(%{pending: %Membrane.Buffer{} = buffer, demand: demand} = state)
       when demand > 0 do
    state = %{
      state
      | pending: nil,
        demand: demand - 1,
        emitted: state.emitted + 1,
        last_ms: now_ms()
    }

    {[buffer: {:output, buffer}], state}
  end

  defp maybe_send(state), do: {[], state}

  # Measured from the last emit, not the last arrival: the rate that matters is
  # the one the model is asked to keep up with.
  defp due?(%{last_ms: nil}), do: true
  defp due?(state), do: now_ms() - state.last_ms >= state.interval_ms

  defp dropped(nil), do: 0
  defp dropped(_buffer), do: 1

  defp now_ms, do: System.monotonic_time(:millisecond)

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
