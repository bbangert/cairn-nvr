defmodule Cairn.Pipeline.DetectSink do
  @moduledoc """
  Terminates the detect branch in `Cairn.Detect.Dispatch` — the cairn-side
  half of what used to be one sink, now that inference is its own generic
  element (`Cairn.Pipeline.Inference`).

  What arrives is that element's `Detections` buffers: observation lists the
  library already projected into source coordinates. This sink turns them
  into `Cairn.Observation`s (`Cairn.Native.Observations`), stamps `at_ms` on
  the host's monotonic clock, and casts them through the dispatch seam with
  the camera's policy — the same cast the plugin ports make, `track:` and
  `record:` carried and unread.

  `policy` is `Cairn.Config.policy/2`, resolved by `Cairn.FFmpegPort` at
  session start and replaced on reload through `Cairn.Pipeline.Camera` —
  never read per frame, as on the plugin path.
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
    epoch: [spec: Cairn.ULID.t()],
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
       epoch: opts.epoch,
       tracker: opts.tracker,
       clock: ObservationClock.new(),
       dispatched: 0,
       dropped: 0
     }}
  end

  # The metadata key is matched, not dot-accessed: `accepted_format` gates the
  # stream-format struct, never buffer metadata, so a producer speaking
  # `Detections` without the observations key falls through to the counted
  # drop below rather than crashing the sink.
  @impl true
  def handle_buffer(:input, %{metadata: %{observations: observations}}, _ctx, state) do
    # Monotonic, as both plugin producers pass: `at_ms` is compared against the
    # host's monotonic clock elsewhere — `Cairn.CameraTracker`'s `cut_clock`
    # stamps a stream cut with it, and a wall-clock `at_ms` puts every
    # suspension a lifetime past its adoption window.
    {observations, clock} =
      Observations.from_frames(
        state.clock,
        observations,
        state.camera.id,
        state.epoch,
        System.monotonic_time(:millisecond)
      )

    # In this process, not the pipeline's: routing through the parent would
    # put the other branches' notifications behind a tracker that is slow to
    # start.
    Dispatch.forward_all(state.camera, state.policy, observations, tracker: state.tracker)

    {[], %{state | clock: clock, dispatched: state.dispatched + length(observations)}}
  end

  def handle_buffer(:input, _buffer, _ctx, state) do
    {[], %{state | dropped: state.dropped + 1}}
  end

  @impl true
  def handle_parent_notification(:stats, _ctx, state) do
    {[notify_parent: {:stats, %{dispatched: state.dispatched, dropped: state.dropped}}], state}
  end

  # A reload cannot change what the argv or the open stream carry — those fields
  # restart the camera (`Cairn.Config.Server`'s `@restart_fields`) and with it
  # this session — so the new pair is swapped in place, exactly as the plugin
  # ports do on `refresh/3`.
  def handle_parent_notification({:policy, camera, policy}, _ctx, state) do
    {[], %{state | camera: camera, policy: policy}}
  end
end
