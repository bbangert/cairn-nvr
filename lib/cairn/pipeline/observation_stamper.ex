defmodule Cairn.Pipeline.ObservationStamper do
  @moduledoc """
  Turns the inference element's detections into clocked, contextualised
  observations for `Membrane.MOTTracker` — the cairn-side half of what used to
  be one sink, now that the tracking itself is a generic element.

  What arrives is `Cairn.Pipeline.Inference`'s `Detections` buffers: observation
  lists the library already projected into source coordinates, tagged with the
  `stream_epoch` of the frame they came from. This filter turns them into
  `Cairn.Observation`s (`Cairn.Native.Observations`), stamps `at_ms` on the
  host's monotonic clock, and emits one
  `Membrane.MOTTracker.Format.Observations` buffer per observation — the
  element's contract, one batch per buffer, in the library's order.

  The epoch is read per buffer rather than held in state: this element outlives
  the sessions it serves, so buffers of the session just ended can still be in
  flight when the next one starts (D8).

  Everything the tracker decides on is resolved here and ships in the buffer's
  `context` (P2-D4), so the tracker element stays policy-agnostic and a reload
  targets this element rather than it — the sink's copy included, which rides
  the same context rather than arriving on a hop of its own. `policy` is
  `Cairn.Config.policy/2`, resolved by `Cairn.PipelineOwner` when it builds the
  pipeline and replaced on reload through `Cairn.Pipeline.Camera` — never read
  per frame, and never resolved twice for one batch. The runtime
  overrides on top of it are read here per buffer,
  from the ETS `Cairn.CameraControl` serves:

    * `min_score` — the camera's **effective** evidence floor, which partitions
      the batch into the tracker's two association stages *and* gates what may
      open an event downstream. Those must be the same number (a box that may
      earn video but may not mint the track carrying it is an event with no
      identity behind it), and since the two decisions now happen in two
      processes it is resolved once here and read off the context in
      `Cairn.CameraTracker`.
    * `detection_enabled` — off means the batch is dropped here rather than
      tracked and thrown away downstream, and the tracker element is told to
      end what it holds (`Membrane.MOTTracker.Event.EndAll`): nothing will
      advance those tracks while detection is off, and a tracker left running
      behind a closed gate would resurrect their identities when it reopens.
  """

  use Membrane.Filter

  alias Cairn.{CameraControl, Config, Tracker}
  alias Cairn.Config.Camera
  alias Cairn.Native.Observations
  alias Cairn.ObservationClock
  alias Cairn.Pipeline.Inference.Detections
  alias Membrane.Buffer
  alias Membrane.MOTTracker.Event.EndAll
  alias Membrane.MOTTracker.Format

  def_input_pad(:input,
    accepted_format: %Detections{},
    flow_control: :auto
  )

  def_output_pad(:output,
    accepted_format: %Format.Observations{},
    flow_control: :auto
  )

  def_options(
    camera: [spec: Camera.t()],
    policy: [spec: map()]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       camera: opts.camera,
       policy: opts.policy,
       clock: ObservationClock.new(),
       # Whether the last buffer found detection enabled, so the tracker is
       # told to end its tracks once per transition and not once per frame.
       detecting?: true,
       stamped: 0,
       dropped: 0
     }}
  end

  # The output format is constant and carries nothing, so it precedes the first
  # buffer rather than depending on one.
  @impl true
  def handle_playing(_ctx, state) do
    {[stream_format: {:output, %Format.Observations{}}], state}
  end

  # Not forwarded: the filter default would push `Detections` onto a pad that
  # accepts `Observations`.
  @impl true
  def handle_stream_format(:input, _format, _ctx, state), do: {[], state}

  # The metadata keys are matched, not dot-accessed: `accepted_format` gates
  # the stream-format struct, never buffer metadata, so a producer speaking
  # `Detections` without the observations key — or without the epoch to tag
  # them with — falls through to the counted drop below rather than crashing
  # the element.
  @impl true
  def handle_buffer(
        :input,
        %Buffer{metadata: %{observations: observations, stream_epoch: epoch}} = buffer,
        _ctx,
        state
      )
      when is_list(observations) and epoch != nil do
    stamp(state, buffer, observations, epoch, CameraControl.get(state.camera.id))
  end

  def handle_buffer(:input, _buffer, _ctx, state) do
    {[], %{state | dropped: state.dropped + 1}}
  end

  defp stamp(state, _buffer, _observations, _epoch, %{detection_enabled: false}) do
    {stop_tracking(state), %{state | detecting?: false, dropped: state.dropped + 1}}
  end

  defp stamp(state, buffer, observations, epoch, control) do
    # Monotonic, and not the wall clock: `at_ms` is compared against the host's
    # monotonic clock elsewhere — `Membrane.MOTTracker` stamps a
    # stream cut with the batch clock and measures the adoption window as a
    # subtraction of two of them, and a wall-clock `at_ms` puts every
    # suspension a lifetime past its window.
    {observations, clock} =
      Observations.from_frames(
        state.clock,
        observations,
        state.camera.id,
        epoch,
        System.monotonic_time(:millisecond)
      )

    policy = tracking_policy(state, control)

    buffers =
      for observation <- observations,
          do: {:buffer, {:output, batch(state, observation, policy, buffer)}}

    {buffers,
     %{
       state
       | clock: clock,
         detecting?: true,
         stamped: state.stamped + length(observations)
     }}
  end

  # One buffer per observation, not per push: the element tracks one batch per
  # buffer, and a push's frames are separate batches with their own instants.
  # `at_ms` rides beside the context as well as inside it: the element times
  # its own work with the one and the core measures its bounds against the
  # other, so both are written from the single reading here — which is what the
  # element's guard checks, being one clock read and not two.
  defp batch(state, observation, policy, buffer) do
    %Buffer{
      payload: <<>>,
      pts: buffer.pts,
      metadata: %{
        objects: observation.objects,
        context: context(state, observation, policy),
        at_ms: observation.at_ms,
        epoch: observation.epoch
      }
    }
  end

  # The pair `Cairn.Pipeline.TrackSink` dispatches with rides the context, which
  # the tracker element carries through opaquely. One reload resolves it and the
  # tracking bounds above together, and only the pad keeps them together: told
  # to both elements out of band, a batch could be stamped under the new
  # tracking policy and dispatched under the old `record:` tier — a combination
  # that never existed in config (D8, a third time).
  defp context(state, observation, policy) do
    observation
    |> Tracker.context(state.camera.id, policy)
    |> Map.put(:dispatch, %{camera: state.camera, policy: state.policy})
  end

  # Detection was on and is now off. Down the pad and not through the parent:
  # the gate can reopen at any moment, and only the pad orders the ending
  # against the batches that follow it — a parent hop lets the flip's second
  # half overtake its first and end the tracks the resumed batches minted.
  defp stop_tracking(%{detecting?: false}), do: []

  defp stop_tracking(_state),
    do: [event: {:output, %EndAll{reason: :detection_disabled}}]

  # A reload cannot change what the argv or the open stream carry — those fields
  # restart the camera (`Cairn.Config.Server`'s `@restart_fields`) and with it
  # this session — so the new pair is swapped in place.
  @impl true
  def handle_parent_notification({:policy, camera, policy}, _ctx, state) do
    {[], %{state | camera: camera, policy: policy}}
  end

  # Defensive on the bounds for the reason `Cairn.Tracker.context/3` documents:
  # a nil where a number belongs would become the tracker's bound. The camera's
  # policy is `Cairn.Config.policy/2` in production and carries all of them.
  defp tracking_policy(state, control) do
    policy = state.policy

    base = %{
      max_unseen_ms: Map.get(policy, :max_unseen_ms) || Config.default_max_unseen_ms(),
      max_live_tracks: Map.get(policy, :max_live_tracks) || Config.default_max_live_tracks(),
      stationary_after_ms:
        Map.get(policy, :stationary_after_ms) || Config.default_stationary_after_ms(),
      # `Map.get/3` where its three neighbours use `||`: these four are
      # booleans, and `||` would read an explicit `false` as an absent key —
      # the same answer only for as long as the default is `false`.
      bbd: Map.get(policy, :bbd, Config.default_bbd()),
      oru: Map.get(policy, :oru, Config.default_oru()),
      ocr: Map.get(policy, :ocr, Config.default_ocr()),
      reid: Map.get(policy, :reid, Config.default_reid()),
      min_score: effective_min_score(state.camera, control)
    }

    # A profiled camera's policy carries a stage presence map, and it rides
    # this hop unmodified — `Cairn.Tracker.context/3` is where it supersedes
    # the booleans above. Absent for every unprofiled camera, whose map stays
    # exactly the pre-profile one.
    case Map.get(policy, :stages) do
      nil -> base
      stages -> Map.put(base, :stages, stages)
    end
  end

  # A runtime min_score override replaces the camera's configured thresholds
  # (applied as the default for every label); nil means "use config". It moves
  # the floor and only the floor — the `record:` tier applies on top of whatever
  # comes out of here, downstream in `Cairn.CameraTracker`.
  defp effective_min_score(camera, %{min_score: nil}), do: camera.min_score
  defp effective_min_score(_camera, %{min_score: override}), do: %{"default" => override}
end
