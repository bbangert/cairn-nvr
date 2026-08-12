defmodule Cairn.Pipeline.Inference do
  @moduledoc """
  Inference as its own element: sampled RGB frames in, observations out — the
  consumer half of D-C2's payload convention, and deliberately generic (D-C5):
  nothing in its options names a camera, a policy or this application.

  ## What it consumes

  `Cairn.Pipeline.Decoder`'s contract, or any producer speaking it:
  `%Membrane.RawVideo{pixel_format: :RGB}` buffers whose payload is the
  tightly-packed content rectangle and whose `metadata` carries
  `orig_width`/`orig_height`, `observed_at_ms`, `stream_epoch` and the
  optional motion verdict. Buffers without those keys (or arriving before a
  stream format) are dropped and counted, never crashed on. `:input` is `:manual` with one
  frame demanded at a time, so the blocking model call bounds the branch's
  *rate*: nothing is demanded while a call is in flight, and the decoder's
  one-frame slot keeps the newest frame for the demand that follows.

  ## What it emits

  One buffer per pushed frame under the
  `%Cairn.Pipeline.Inference.Detections{}` stream format: `payload` is empty,
  `pts` is the input buffer's, `metadata.stream_epoch` is the input frame's,
  and `metadata.observations` is the library's own frame-observation list —
  boxes already projected back to source coordinates (the letterbox maths
  crossed with the frame, and the library applied them; nothing downstream
  re-derives geometry). There is no
  ecosystem convention for a detections pad to defer to — this element is the
  first — so the shape is deliberately minimal.

  ## The session

  `session: {module, server}` is the provider of the inference session —
  anything with `open_stream(server, stream_id, params)`,
  `push_frame(server, stream_id, payload, meta, time_base)` and
  `close_stream(server, stream_id)` in `CairnOrt`'s error vocabulary. In this
  application that is `Cairn.Native.Host`, which multiplexes one shared
  engine (one model, one HTP graph) across every camera; a standalone user
  can wrap `CairnOrt` in a GenServer of the same shape. The stream is opened
  under one epoch — `stream_params.stream_epoch`, fixed at open, since
  `push_frame/5` carries none — so the element cannot open before the first
  frame tells it which session it is serving, and a frame whose
  `stream_epoch` differs closes the stream and reopens under the new one.
  That reopen is a reconfiguration, not a failure: it does not wait out the
  cooldown a refused or lost stream does. Beyond it the element reopens on a
  cooldown after stream-fatal errors, and parks permanently on an
  engine-fatal one — the session owner's
  recovery (a fresh model load behind its canary) is not this element's to
  drive. The provider calls themselves are plain `GenServer.call`s: the
  provider's liveness is the deployment's to supervise (in this application
  the Host sits outside every camera's tree), so a missing provider is a
  boot-order fault that should crash this element, not a state to retry
  around.
  """

  use Membrane.Filter

  require Logger

  defmodule Detections do
    @moduledoc """
    The stream format `Cairn.Pipeline.Inference` emits: observation lists in
    `buffer.metadata.observations`, empty payloads. A struct with no fields —
    the per-buffer variability all rides the buffers, and the format exists so
    a pad can declare what it accepts.
    """
    defstruct []
  end

  alias Membrane.Buffer

  def_input_pad(:input,
    accepted_format: %Membrane.RawVideo{pixel_format: :RGB},
    flow_control: :manual,
    demand_unit: :buffers
  )

  def_output_pad(:output,
    accepted_format: %Detections{},
    flow_control: :auto
  )

  def_options(
    session: [
      spec: {module(), term()},
      description:
        "The inference-session provider: `{module, server}` with open_stream/3, " <>
          "push_frame/5 and close_stream/2 in CairnOrt's error vocabulary"
    ],
    stream_id: [spec: String.t()],
    stream_params: [
      spec: map(),
      default: %{},
      description:
        "The provider's stream vocabulary (score floors, motion knobs); " <>
          "`stream_epoch` is not among them — it comes from the frames"
    ],
    reopen_cooldown_ms: [
      spec: non_neg_integer(),
      default: 5_000,
      description: "How long a refused open or a lost stream waits before the next attempt"
    ]
  )

  # Membrane buffer timestamps are `Membrane.Time` (nanoseconds); the library
  # rescales to 90 kHz itself (`decode::rescale_90k`).
  @time_base {1, 1_000_000_000}

  # `CairnOrt`'s taxonomy. The engine-fatal pair only comes back through the
  # session owner's recovery, so retrying against it would spin; the
  # stream-fatal ones cost this stream its handle and are remedied by
  # reopening. Everything else is per frame as often as per stream.
  @engine_fatal [:model_load, :model_poisoned]
  @stream_fatal [:closed, :poisoned, :panicked]

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       session: opts.session,
       stream_id: opts.stream_id,
       params: opts.stream_params,
       cooldown_ms: opts.reopen_cooldown_ms,
       stream: :closed,
       engine: :ok,
       retry_at: nil,
       content: nil,
       pushed: 0,
       dropped: 0,
       errors: 0
     }}
  end

  @impl true
  def handle_setup(ctx, state) do
    %{session: {module, server}, stream_id: stream_id} = state

    # Registered before the stream exists, so a crash between open and teardown
    # still hands the stream id back — until it does, no later session for this
    # id can open one.
    Membrane.ResourceGuard.register(ctx.resource_guard, fn ->
      module.close_stream(server, stream_id)
    end)

    {[], state}
  end

  # Nothing is opened here: the epoch a stream is opened under arrives on the
  # first frame, and this element outlives the sessions it serves.
  @impl true
  def handle_playing(_ctx, state) do
    # The output format is constant and carries nothing, so it precedes the
    # first demand rather than the first buffer.
    {[stream_format: {:output, %Detections{}}] ++ demand(state), state}
  end

  # The payload's own geometry rides the stream format, not per-buffer
  # metadata: it is fixed for the life of the scaler that produced it. The
  # input format is NOT forwarded — the filter default would push RawVideo
  # onto the Detections pad.
  @impl true
  def handle_stream_format(:input, %Membrane.RawVideo{} = format, _ctx, state) do
    {[], %{state | content: {format.width, format.height}}}
  end

  @impl true
  def handle_buffer(:input, %Buffer{metadata: %{stream_epoch: epoch}} = buffer, _ctx, state)
      when epoch != nil do
    {actions, state} = state |> for_epoch(epoch) |> ensure_stream() |> infer(buffer)
    {actions ++ demand(state), state}
  end

  # An untagged frame names no session, so it can neither be pushed nor decide
  # what the stream should be open under: dropped and counted, stream untouched.
  def handle_buffer(:input, _buffer, _ctx, state) do
    state = %{state | dropped: state.dropped + 1}
    {demand(state), state}
  end

  @impl true
  def handle_parent_notification(:stats, _ctx, state) do
    stats = %{
      pushed: state.pushed,
      dropped: state.dropped,
      errors: state.errors,
      stream: state.stream,
      engine: state.engine
    }

    {[notify_parent: {:stats, stats}], state}
  end

  # A dead engine serves no stream until the session owner's recovery, so the
  # element stops demanding rather than calling into it once per frame. The
  # decoder's slot then holds the newest frame, cheaply, for the rest of the
  # session.
  defp demand(%{engine: :dead}), do: []
  defp demand(_state), do: [demand: {:input, 1}]

  defp infer(%{engine: :dead} = state, _buffer), do: {[], state}

  # The metadata keys are matched, not dot-accessed: a producer that speaks
  # RGB frames without the decoder's metadata contract falls through to the
  # counted drop below rather than crashing the element on a `KeyError`.
  defp infer(
         %{stream: :open, content: {width, height}, session: {module, server}} = state,
         %Buffer{
           metadata:
             %{
               orig_width: orig_width,
               orig_height: orig_height,
               observed_at_ms: observed_at_ms,
               stream_epoch: stream_epoch
             } = metadata
         } = buffer
       ) do
    meta = %{
      width: width,
      height: height,
      orig_width: orig_width,
      orig_height: orig_height,
      pts: buffer.pts,
      observed_at_ms: observed_at_ms,
      motion: Map.get(metadata, :motion)
    }

    case module.push_frame(server, state.stream_id, buffer.payload, meta, @time_base) do
      {:ok, {observations, _ended_tracks}} ->
        out = %Buffer{
          payload: <<>>,
          pts: buffer.pts,
          # Carried, not re-read from `params`: the tag belongs to the frame
          # these observations came from, which is what a consumer stamping
          # them at production time needs.
          metadata: %{observations: observations, stream_epoch: stream_epoch}
        }

        {[buffer: {:output, out}], %{state | pushed: state.pushed + 1}}

      # The parent is deliberately not told: it could do nothing with it. This
      # element stops demanding; the session owner owns the recovery, and the
      # branch comes back with the next pipeline.
      {:error, {reason, message}} when reason in @engine_fatal ->
        Logger.error("inference #{state.stream_id}: stopped, the engine is #{reason}: #{message}")

        {[], %{state | engine: :dead, errors: state.errors + 1}}

      {:error, {reason, _message}} when reason in @stream_fatal ->
        # The provider has already dropped the handle; the next frame reopens.
        {[], reopen_later(state)}

      {:error, :no_stream} ->
        {[], reopen_later(state)}

      {:error, _transient} ->
        {[], %{state | errors: state.errors + 1}}
    end
  end

  # A buffer while `stream: :closed` waits out its reopen cooldown, or one
  # without the metadata contract, or one that somehow preceded its stream
  # format: dropped, and *counted* — a stuck reopen loop must not read as
  # healthy in `:stats` while quietly discarding frames.
  defp infer(state, _buffer), do: {[], %{state | dropped: state.dropped + 1}}

  defp reopen_later(state) do
    %{state | stream: :closed, errors: state.errors + 1, retry_at: now_ms() + state.cooldown_ms}
  end

  # The epoch is fixed at `open_stream` (`push_frame/5` carries none), so a new
  # session is a new stream. The cooldown is cleared with it: a refused open
  # this element is waiting out was made for the OLD session and says nothing
  # about the new one — the same reasoning `Cairn.Pipeline.Decoder` applies to
  # a geometry change.
  # A parked element calls into its provider for nothing, boundary included.
  defp for_epoch(%{engine: :dead} = state, _epoch), do: state

  defp for_epoch(state, epoch) do
    if Map.get(state.params, :stream_epoch) == epoch do
      state
    else
      %{close_stream(state) | params: Map.put(state.params, :stream_epoch, epoch), retry_at: nil}
    end
  end

  defp close_stream(%{stream: :open, session: {module, server}} = state) do
    module.close_stream(server, state.stream_id)
    %{state | stream: :closed}
  end

  defp close_stream(state), do: state

  defp ensure_stream(%{stream: :open} = state), do: state
  defp ensure_stream(%{engine: :dead} = state), do: state

  # Monotonic milliseconds, which start negative on the BEAM: nothing here may
  # read the value as a sign.
  defp ensure_stream(%{retry_at: retry_at} = state) when is_integer(retry_at) do
    if now_ms() >= retry_at, do: open(state), else: state
  end

  defp ensure_stream(state), do: open(state)

  defp open(%{session: {module, server}} = state) do
    case module.open_stream(server, state.stream_id, state.params) do
      {:ok, _} ->
        %{state | stream: :open, retry_at: nil}

      {:error, reason} ->
        # Not fatal to the session: the engine may still be loading its model,
        # and the next frame past the cooldown tries again.
        Logger.warning("inference #{state.stream_id}: no stream (#{inspect(reason)})")
        %{state | retry_at: now_ms() + state.cooldown_ms}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
