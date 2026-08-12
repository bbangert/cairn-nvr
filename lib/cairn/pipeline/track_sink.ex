defmodule Cairn.Pipeline.TrackSink do
  @moduledoc """
  Terminates the detect branch in `Cairn.Detect.Dispatch`: `Membrane.MOTTracker`'s
  identities and lifecycle events in, one cast per batch to the camera's
  `Cairn.CameraTracker` out.

  Everything the event lifecycle needs is on the buffer already — the tagged
  objects, the transitions, the checkpoint snapshot taken after them, and the
  context the batch was tracked with. This element reads none of it beyond
  unpacking it into the cast: what a batch *means* is the camera tracker's
  business, and a decision taken here would be taken on the branch's own
  thread, between two frames of a camera that is still decoding.

  `policy` is `Cairn.Config.policy/2`, resolved by `Cairn.PipelineOwner` when it
  builds the pipeline and replaced on reload through `Cairn.Pipeline.Camera` —
  carried with every cast and unread here.
  """

  use Membrane.Sink

  alias Cairn.Config.Camera
  alias Cairn.Detect.Dispatch
  alias Membrane.Buffer
  alias Membrane.MOTTracker.Format

  def_input_pad(:input,
    accepted_format: %Format.Tracks{},
    flow_control: :auto
  )

  def_options(
    camera: [spec: Camera.t()],
    policy: [spec: map()],
    tracker: [
      spec: GenServer.server() | nil,
      default: nil,
      description: "`Cairn.Detect.Dispatch`'s injection seam; the camera's own tracker when nil"
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       camera: opts.camera,
       policy: opts.policy,
       tracker: opts.tracker,
       dispatched: 0,
       dropped: 0,
       last_buffer_at_ms: nil
     }}
  end

  # The metadata keys are matched, not dot-accessed, for the reason every
  # element on this branch matches them: `accepted_format` gates the
  # stream-format struct and never the buffer, so a producer speaking `Tracks`
  # without the contract is a counted drop rather than a crash.
  @impl true
  def handle_buffer(
        :input,
        %Buffer{
          metadata: %{tagged: tagged, events: events, snapshot: snapshot, epoch: epoch} = metadata
        },
        _ctx,
        state
      )
      when is_list(tagged) and is_list(events) and is_list(snapshot) do
    batch = batch(metadata, tagged, events, snapshot, epoch)

    # In this process, not the pipeline's: routing through the parent would put
    # the other branches' notifications behind a tracker that is slow to start.
    # Load-bearing: `forward/4` is a cast — were it ever a call, a slow
    # CameraTracker would backpressure this branch through the sink.
    Dispatch.forward(state.camera, state.policy, batch, tracker: state.tracker)

    {[], %{state | dispatched: state.dispatched + 1, last_buffer_at_ms: liveness(state, batch)}}
  end

  def handle_buffer(:input, _buffer, _ctx, state) do
    {[], %{state | dropped: state.dropped + 1}}
  end

  # The context is flattened to the two things the event lifecycle reads off it,
  # so the tracker vocabulary stops here: `observed_at` — every time in an event
  # derives from the observation rather than from a clock read downstream — and
  # the effective `min_score` the batch was associated on, which is the same
  # number the event gate has to use (see `Cairn.Pipeline.ObservationStamper`).
  # Both are `nil` on the element's own buffers, which answer to no batch and
  # carry nothing but finals.
  defp batch(metadata, tagged, events, snapshot, epoch) do
    context = Map.get(metadata, :context)

    %{
      tagged: tagged,
      events: events,
      snapshot: snapshot,
      suspension: Map.get(metadata, :suspension),
      epoch: epoch,
      observed_at: context && Map.get(context, :observed_at),
      min_score: context && Map.get(context, :min_score)
    }
  end

  # Only a batch that came from a frame is a sign of life: `Membrane.MOTTracker`
  # emits buffers of its own when a suspension lapses with the stream still
  # down, and letting those refresh the stamp would vouch for a branch that
  # has decoded nothing since the cut.
  defp liveness(state, %{observed_at: nil}), do: state.last_buffer_at_ms
  defp liveness(_state, _batch), do: System.monotonic_time(:millisecond)

  # `dispatched` counts every batch, the element's own included, so what the
  # watchdog reads is the *age* above rather than this. Monotonic milliseconds,
  # which start negative on the BEAM: only a reader's own
  # `System.monotonic_time/1` may be subtracted from it.
  @impl true
  def handle_parent_notification(:stats, _ctx, state) do
    stats = %{
      dispatched: state.dispatched,
      dropped: state.dropped,
      last_buffer_at_ms: state.last_buffer_at_ms
    }

    {[notify_parent: {:stats, stats}], state}
  end

  def handle_parent_notification({:policy, camera, policy}, _ctx, state) do
    {[], %{state | camera: camera, policy: policy}}
  end
end
