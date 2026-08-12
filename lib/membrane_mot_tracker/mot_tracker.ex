defmodule Membrane.MOTTracker do
  @moduledoc """
  Multi-object tracking as a filter: batches of detections in, identities and
  lifecycle events out.

  The tracking itself is a `Membrane.MOTTracker.Core` named by the `tracker:`
  option — this element owns the state threading, the pad contract and the
  session lifecycle around them, so swapping trackers is a config change rather
  than a rewiring.

  Nothing here names a camera, a policy or a clock. The batch's instant and its
  resolved thresholds are stamped upstream and ride each buffer
  (`Membrane.MOTTracker.Format.Observations`), which is what lets the element
  outlive the sessions it tracks: it holds tracker state, and every decision
  taken on that state belongs to the buffer that provoked it, not to when the
  element got round to it.

  ## The session lifecycle

  A buffer whose `epoch` differs from the last one seen crossed a stream
  boundary nothing observed. The live tracks are **suspended** before that
  buffer's own objects are tracked (`c:Membrane.MOTTracker.Core.suspend/3`), so
  a detection in the new session can adopt an identity the outage interrupted
  rather than mint a second one for it — and it cannot adopt a track that is
  still live. A repeated announcement of the same epoch crosses nothing and is
  a no-op.

  What nothing adopts has to end anyway, and on a stream that never comes back
  no buffer arrives to notice that. So each cut arms one timer, past the core's
  adoption window; its tick expires the suspensions and emits their finals on a
  buffer of the element's own.

  A deliberate stop — the `:end_all` parent notification, or end of stream on
  the input — ends everything the core is still holding, under the reason the
  parent gave (`{:end_all, reason}`) or `:stream_reset` for the ones that name
  none. A pipeline rebuild is not a stop and needs no handling: the element
  dies with it, and the tracks die with the element.

  A buffer that does not carry the metadata contract is dropped and counted,
  never crashed on, and `:stats` reports the two counters to the parent.
  """

  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.MOTTracker.{Core, Format}
  alias Membrane.Time

  # The one timer id, so a cut can only ever restart the sweep it already has.
  @sweep :adoption_window

  def_input_pad(:input,
    accepted_format: %Format.Observations{},
    flow_control: :auto
  )

  def_output_pad(:output,
    accepted_format: %Format.Tracks{},
    flow_control: :auto
  )

  def_options(
    tracker: [
      spec: {module(), keyword()},
      description:
        "The tracker core as `{module, opts}`: a `Membrane.MOTTracker.Core` " <>
          "implementation and the options it is built with"
    ],
    max_suspended: [
      spec: pos_integer(),
      default: 128,
      description:
        "How many tracks a stream boundary may keep waiting for adoption. " <>
          "The default is the live-track cap a host that sets nothing gets: a " <>
          "camera cannot suspend more tracks than it was allowed to hold"
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {module, core_opts} = opts.tracker
    ensure_core!(module)

    {[],
     %{
       module: module,
       core: module.new(core_opts),
       epoch: nil,
       max_suspended: opts.max_suspended,
       # How long after a cut the sweep runs, or `nil` for a core that declares
       # by omission that it keeps nothing adoptable (the callback is optional)
       # — such a core is armed no timer at all. Past the window rather than at
       # it, for the reason `sweep_at/1` gives.
       window_ms: window_ms(module),
       # the cut the armed sweep is waiting on, and whether one is armed —
       # `stop_timer` on a timer that was never started raises
       cut_ms: nil,
       sweeping?: false,
       processed: 0,
       dropped: 0
     }}
  end

  defp window_ms(module) do
    if function_exported?(module, :adoption_window_ms, 0) do
      module.adoption_window_ms() + 1_000
    end
  end

  # The output format is constant and carries nothing, so it precedes the first
  # buffer rather than depending on one.
  @impl true
  def handle_playing(_ctx, state) do
    {[stream_format: {:output, %Format.Tracks{}}], state}
  end

  # The input format is not forwarded: the filter default would push
  # Observations onto the Tracks pad.
  @impl true
  def handle_stream_format(:input, _format, _ctx, state), do: {[], state}

  # `at_ms` is the element's own handle on the tracking clock: the batch's
  # instant, beside the context rather than read out of it. It is the only
  # reading of that clock this element gets, so it is what a cut is stamped
  # with and what the sweep's instant is derived from.
  @impl true
  def handle_buffer(
        :input,
        %Buffer{metadata: %{objects: objects, context: context, at_ms: at_ms, epoch: epoch}} =
          buffer,
        _ctx,
        state
      )
      when is_list(objects) and is_map(context) do
    {timers, severed, suspension, state} = cut(state, epoch, at_ms)
    {core, tagged, events} = state.module.track(state.core, objects, context)

    out = %Buffer{
      payload: <<>>,
      pts: buffer.pts,
      metadata: %{
        tagged: tagged,
        # The cut's finals lead this batch's, which is the order they happened
        # in and the order a consumer has to apply them: a track severed by the
        # boundary ended before anything here was tracked.
        events: severed ++ events,
        suspension: suspension,
        snapshot: state.module.checkpoint_tracks(core),
        # The buffer's, not the element's: these tracks were observed under the
        # session the observations came from.
        epoch: epoch,
        context: context
      }
    }

    state = %{state | core: core, processed: state.processed + 1}

    {timers ++ [buffer: {:output, out}], state}
  end

  def handle_buffer(:input, _buffer, _ctx, state) do
    {[], %{state | dropped: state.dropped + 1}}
  end

  # Nothing observed the boundary, so the live tracks may not go on matching
  # across it — they are suspended here, before this buffer's objects reach the
  # core, because a detection can only adopt a track that is no longer live.
  #
  # The cut is this buffer's `at_ms`. A cut has to be on the batch clock — the
  # core measures the adoption window as a subtraction of two of them — and
  # this is the only reading of that clock a boundary comes with: the new
  # session's first batch, stamped where it was observed. Taking the *previous*
  # buffer's instead would date the cut at the start of the outage rather than
  # at its end, and spend the window waiting through the gap the window exists
  # to survive. It is also the only choice that cannot hand the core a cut
  # later than the batch that immediately follows it.
  defp cut(%{epoch: epoch} = state, epoch, _at_ms), do: {[], [], nil, state}

  # Nothing was seen before, so nothing was cut: the first buffer of a freshly
  # started element only sets the epoch it is tracking under.
  #
  # It is the *element's* epoch being nil that says so, not the buffer's — so a
  # producer that sends untagged batches and then starts tagging them crosses
  # no boundary here, however many tracks the untagged ones minted. A producer
  # is expected to tag every buffer or none; dropping the untagged ones is the
  # host's business (`accepted_format` cannot gate metadata), and one that
  # mixes the two gets this reading rather than a cut.
  defp cut(%{epoch: nil} = state, epoch, _at_ms), do: {[], [], nil, %{state | epoch: epoch}}

  defp cut(state, epoch, at_ms) do
    {core, events, suspension} =
      state.module.suspend(state.core, state.max_suspended, at_ms)

    {actions, state} = arm_sweep(%{state | core: core, epoch: epoch}, at_ms)
    {actions, events, suspension, state}
  end

  defp arm_sweep(%{window_ms: nil} = state, _cut_ms), do: {[], state}

  # One armed sweep per element, restarted at every cut: a camera flapping
  # between sessions must not accumulate a timer per attempt, and the sweep it
  # restarts was waiting on a cut that this one supersedes.
  defp arm_sweep(state, cut_ms) do
    stop = if state.sweeping?, do: [stop_timer: @sweep], else: []

    {stop ++ [start_timer: {@sweep, Time.milliseconds(state.window_ms)}],
     %{state | cut_ms: cut_ms, sweeping?: true}}
  end

  # The stream never came back: no batch arrived to notice the window running
  # out, and the finals the core still owes would otherwise never go out.
  #
  # It does not re-arm. Every suspension the core holds was made at or before
  # the last cut — a later one would have restarted this timer — so a single
  # sweep past that cut's window collects all of them and leaves none behind.
  @impl true
  def handle_tick(@sweep, _ctx, state) do
    {core, expired} = state.module.expire_suspended(state.core, sweep_at(state))
    state = %{state | core: core, sweeping?: false}

    {[stop_timer: @sweep] ++ announce(state, expired), state}
  end

  # The element reads no clock — the batch clock is the producer's (see the
  # moduledoc) — so the sweep's instant is derived rather than read: the tick
  # waited `window_ms` out, so the cut plus that wait is what the batch clock
  # now says, give or take the drift between two clocks that both track real
  # time. It errs behind rather than ahead, which is the safe direction: a
  # suspension is never ended before its window is out. The slack `window_ms`
  # carries over the core's own window is what puts this *past* the window
  # rather than exactly on it, which a core comparing the elapsed time
  # inclusively would not call lapsed.
  defp sweep_at(state), do: state.cut_ms + state.window_ms

  # Deliberate stops. The rebuild case is absent on purpose: a pipeline that is
  # torn down takes this element with it, and the tracks with the element.
  @impl true
  def handle_parent_notification({:end_all, reason}, _ctx, state) do
    end_all(state, reason)
  end

  def handle_parent_notification(:end_all, _ctx, state) do
    end_all(state)
  end

  def handle_parent_notification(:stats, _ctx, state) do
    {[notify_parent: {:stats, %{processed: state.processed, dropped: state.dropped}}], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    {actions, state} = end_all(state)
    {actions ++ [end_of_stream: :output], state}
  end

  defp end_all(state, reason \\ :stream_reset) do
    {core, ended} = state.module.end_all(state.core, reason)
    stop = if state.sweeping?, do: [stop_timer: @sweep], else: []
    state = %{state | core: core, sweeping?: false}

    {stop ++ announce(state, ended), state}
  end

  # Events with no batch to ride, on a buffer of their own: a consumer that
  # waited for the next detection to hear about a suspension would wait exactly
  # as long as the stream stays down. Nothing is emitted for an empty list —
  # a buffer carrying no events and no objects tells a consumer nothing.
  defp announce(_state, []), do: []

  defp announce(state, events) do
    [
      buffer:
        {:output,
         %Buffer{
           payload: <<>>,
           metadata: %{
             tagged: [],
             events: events,
             suspension: nil,
             snapshot: state.module.checkpoint_tracks(state.core),
             epoch: state.epoch,
             context: nil
           }
         }}
    ]
  end

  # Checked at init rather than trusted at the first buffer: a mistyped core
  # module is a wiring fault, and the pipeline that owns this element should
  # fail while it is being built, not once a camera streams.
  defp ensure_core!(module) do
    Code.ensure_loaded!(module)

    behaviours =
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    unless Core in behaviours do
      raise ArgumentError, "#{inspect(module)} does not implement #{inspect(Core)}"
    end
  end
end
