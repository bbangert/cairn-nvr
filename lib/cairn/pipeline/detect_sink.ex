defmodule Cairn.Pipeline.DetectSink do
  @moduledoc """
  Terminates the detect branch in `Cairn.Detect.Dispatch` — the cairn-side
  half of what used to be one sink, now that inference is its own generic
  element (`Cairn.Pipeline.Inference`).

  What arrives is that element's `Detections` buffers: observation lists the
  library already projected into source coordinates, tagged with the
  `stream_epoch` of the frame they came from. This sink turns them into
  `Cairn.Observation`s (`Cairn.Native.Observations`), stamps `at_ms` on the
  host's monotonic clock, and casts them through the dispatch seam with the
  camera's policy — the same cast the plugin ports make, `track:` and
  `record:` carried and unread.

  The epoch is read per buffer rather than held in state: this element
  outlives the sessions it serves, so buffers of the session just ended can
  still be in flight when the next one starts (D8).

  `policy` is `Cairn.Config.policy/2`, resolved by `Cairn.PipelineOwner` when
  it builds the pipeline and replaced on reload through
  `Cairn.Pipeline.Camera` — never read per frame, as on the plugin path.
  """

  use Membrane.Sink

  alias Cairn.Config.Camera
  alias Cairn.Detect.Dispatch
  alias Cairn.Native.Observations
  alias Cairn.ObservationClock
  alias Cairn.Pipeline.Inference.Detections

  def_input_pad(:input,
    accepted_format: %Detections{},
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
       clock: ObservationClock.new(),
       dispatched: 0,
       dropped: 0,
       last_buffer_at_ms: nil
     }}
  end

  # The metadata keys are matched, not dot-accessed: `accepted_format` gates
  # the stream-format struct, never buffer metadata, so a producer speaking
  # `Detections` without the observations key — or without the epoch to tag
  # them with — falls through to the counted drop below rather than crashing
  # the sink.
  @impl true
  def handle_buffer(
        :input,
        %{metadata: %{observations: observations, stream_epoch: epoch}},
        _ctx,
        state
      )
      when epoch != nil do
    # Monotonic, as both plugin producers pass: `at_ms` is compared against the
    # host's monotonic clock elsewhere — `Cairn.CameraTracker`'s `cut_clock`
    # stamps a stream cut with it, and a wall-clock `at_ms` puts every
    # suspension a lifetime past its adoption window.
    {observations, clock} =
      Observations.from_frames(
        state.clock,
        observations,
        state.camera.id,
        epoch,
        System.monotonic_time(:millisecond)
      )

    # In this process, not the pipeline's: routing through the parent would
    # put the other branches' notifications behind a tracker that is slow to
    # start.
    Dispatch.forward_all(state.camera, state.policy, observations, tracker: state.tracker)

    {[],
     %{
       state
       | clock: clock,
         dispatched: state.dispatched + length(observations),
         last_buffer_at_ms: System.monotonic_time(:millisecond)
     }}
  end

  def handle_buffer(:input, _buffer, _ctx, state) do
    {[], %{state | dropped: state.dropped + 1}}
  end

  # `dispatched` counts observations, so a quiet scene and a wedged branch move
  # it identically — not at all. The age of the last *buffer* is what separates
  # them, and it is what the watchdog reads. Monotonic milliseconds, which
  # start negative on the BEAM: only a reader's own `System.monotonic_time/1`
  # may be subtracted from it.
  @impl true
  def handle_parent_notification(:stats, _ctx, state) do
    stats = %{
      dispatched: state.dispatched,
      dropped: state.dropped,
      last_buffer_at_ms: state.last_buffer_at_ms
    }

    {[notify_parent: {:stats, stats}], state}
  end

  # A reload cannot change what the argv or the open stream carry — those fields
  # restart the camera (`Cairn.Config.Server`'s `@restart_fields`) and with it
  # this session — so the new pair is swapped in place, exactly as the plugin
  # ports do on `refresh/3`.
  def handle_parent_notification({:policy, camera, policy}, _ctx, state) do
    {[], %{state | camera: camera, policy: policy}}
  end
end
