defmodule Cairn.Pipeline.MotionGate do
  @moduledoc """
  Motion measurement as its own element: RGB frames in, the same frames out
  with a `motion` verdict in the metadata — so the gate is pluggable in
  front of *any* inference element, which is the piece with no equivalent
  anywhere in the Elixir ecosystem.

  The measurement is `Cairn.Motion`, the exact Nx port of the crate's
  detector (D-C3): the verdict written here is indistinguishable from the
  one the decode NIF mints when it measures, four keys
  (`t:Cairn.Motion.verdict/0`), so consumers — `Cairn.Pipeline.Inference`'s
  metadata mapping, the inference library's gate policy — cannot tell which
  side measured. This element only measures; *acting* on the verdict
  (linger, epoch bypass, re-verify) stays with whoever runs the model,
  because skipping work is a policy about the model pass, not about the
  picture.

  Both pads are `:manual` and demand passes through one-for-one, keeping the
  upstream decoder's one-frame-in-flight seam intact: an `:auto` input here
  would put a queue of aging frames between the decoder's latest-wins slot
  and the model. One consequence is deliberate and differs from the NIF-side
  measurement, which ran at decode time: a frame the decoder *replaces*
  under backpressure is never observed here, so the background and the
  frame-counted calibration window advance only on frames that actually
  reach the gate — the gate observes exactly what it gates.

  The detector restarts its calibration on a geometry change by itself; this
  element just rebuilds the downsample plan when a new stream format
  arrives, and forwards the format unchanged.
  """

  use Membrane.Filter

  alias Cairn.Motion
  alias Cairn.Motion.Thumbnail
  alias Membrane.Buffer

  def_input_pad(:input,
    accepted_format: %Membrane.RawVideo{pixel_format: :RGB},
    flow_control: :manual,
    demand_unit: :buffers
  )

  def_output_pad(:output,
    accepted_format: %Membrane.RawVideo{pixel_format: :RGB},
    flow_control: :manual
  )

  def_options(
    config: [
      spec: Motion.Config.t(),
      description:
        "The resolved knobs (`Cairn.Motion.Config.resolve_json/1`) — an element " <>
          "only exists for an enabled gate; a disabled one is no element at all"
    ],
    sample_fps: [
      spec: pos_integer(),
      description:
        "The producer's sample rate, sizing the frame-counted calibration window " <>
          "exactly as the crate resolves it from `--sample-fps`"
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       detector: Motion.new(opts.config, opts.sample_fps),
       plan: nil,
       observed: 0,
       motion: 0,
       scene_cuts: 0
     }}
  end

  # The format is forwarded as-is — this filter transmutes metadata, not
  # frames — but explicitly, with the plan rebuilt for the new geometry.
  @impl true
  def handle_stream_format(:input, %Membrane.RawVideo{} = format, _ctx, state) do
    {[stream_format: {:output, format}],
     %{state | plan: Thumbnail.plan(format.width, format.height)}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {[demand: {:input, size}], state}
  end

  @impl true
  def handle_buffer(:input, %Buffer{} = buffer, _ctx, state) do
    thumb = Thumbnail.from_rgb24(buffer.payload, state.plan)
    {verdict, detector} = Motion.observe(state.detector, thumb)
    out = %{buffer | metadata: Map.put(buffer.metadata, :motion, verdict)}

    state = %{
      state
      | detector: detector,
        observed: state.observed + 1,
        motion: state.motion + if(verdict.motion, do: 1, else: 0),
        scene_cuts: state.scene_cuts + if(verdict.scene_cut, do: 1, else: 0)
    }

    {[buffer: {:output, out}], state}
  end

  @impl true
  def handle_parent_notification(:stats, _ctx, state) do
    stats = %{
      observed: state.observed,
      motion: state.motion,
      scene_cuts: state.scene_cuts,
      calibrating: state.detector.frames < state.detector.calibration_frames
    }

    {[notify_parent: {:stats, stats}], state}
  end
end
