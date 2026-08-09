defmodule Cairn.Pipeline.InferSink do
  @moduledoc """
  Terminates the detect branch in `Cairn.Native.Host.push_au/5`.

  `:input` is `:manual` and exactly one AU is demanded at a time, so the blocking
  native call bounds the branch's *rate* rather than its latency: nothing is
  demanded while a call is in flight, and `Cairn.Pipeline.Picker` sheds whatever
  arrives meanwhile. This pad is the manual seam and it belongs here, one hop
  before the expensive call — a manual input pad attached straight to the tee
  would arm membrane_core's toilet, which kills the receiver past ~200 buffers
  (`Membrane.Core.Element.AtomicDemand`).

  The stream is opened for the pipeline's session (one ffmpeg run, one epoch) and
  closed with it.

  Observations leave through `Cairn.Detect.Dispatch`, the seam the plugin ports
  use. `policy` is `Cairn.Config.policy/2`, resolved by `Cairn.FFmpegPort` at
  session start and replaced on reload through `Cairn.Pipeline.Camera` — never
  read per frame, as on the plugin path.
  """

  use Membrane.Sink

  require Logger

  alias Cairn.Config.Camera
  alias Cairn.Detect.Dispatch
  alias Cairn.Native.Host
  alias Cairn.Native.Observations
  alias Cairn.ObservationClock

  def_input_pad(:input,
    accepted_format: %Membrane.H264{alignment: :au},
    flow_control: :manual,
    demand_unit: :buffers
  )

  def_options(
    camera: [spec: Camera.t()],
    policy: [spec: map()],
    epoch: [spec: Cairn.ULID.t()],
    host: [spec: atom(), default: Cairn.Native.Host],
    stream_params: [
      spec: map(),
      default: %{},
      description: "`Cairn.Native.Config.stream_params/1` vocabulary, minus the epoch"
    ],
    reopen_cooldown_ms: [
      spec: non_neg_integer(),
      default: 5_000,
      description: "How long a refused open or a lost stream waits before the next attempt"
    ],
    tracker: [
      spec: GenServer.server() | nil,
      default: nil,
      description: "`Cairn.Detect.Dispatch`'s injection seam; the camera's own tracker when nil"
    ]
  )

  # Membrane buffer timestamps are `Membrane.Time` (nanoseconds); the crate
  # rescales to 90 kHz itself (`decode::pts_90k`).
  @time_base {1, 1_000_000_000}

  # `Cairn.Native.Host`'s taxonomy, which it does not export. The engine-fatal
  # pair only comes back through `configure/3`, so retrying against it would
  # spin; the stream-fatal ones cost this camera its handle and are remedied by
  # reopening. Everything else is per frame as often as per stream, and the
  # host's cross-stream health check is what judges those.
  @engine_fatal [:model_load, :model_poisoned]
  @stream_fatal [:closed, :poisoned, :panicked]

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       camera: opts.camera,
       policy: opts.policy,
       epoch: opts.epoch,
       host: opts.host,
       tracker: opts.tracker,
       cooldown_ms: opts.reopen_cooldown_ms,
       params: Map.put(opts.stream_params, :stream_epoch, opts.epoch),
       clock: ObservationClock.new(),
       stream: :closed,
       engine: :ok,
       retry_at: nil,
       pushed: 0,
       errors: 0
     }}
  end

  @impl true
  def handle_setup(ctx, state) do
    camera_id = state.camera.id

    # Registered before the stream exists, so a crash between open and teardown
    # still hands the camera id back to the crate — until it does, no later
    # session for this camera can open one.
    Membrane.ResourceGuard.register(ctx.resource_guard, fn ->
      Host.close_stream(state.host, camera_id)
    end)

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    state = ensure_stream(state)
    {demand(state), state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    {actions, state} = state |> ensure_stream() |> infer(buffer)
    {actions ++ demand(state), state}
  end

  @impl true
  def handle_parent_notification(:stats, _ctx, state) do
    stats = %{
      pushed: state.pushed,
      errors: state.errors,
      stream: state.stream,
      engine: state.engine
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

  # A dead engine serves no camera until an operator's `configure/3`, so the sink
  # stops demanding rather than calling into it once per AU. The picker then
  # drops everything, cheaply, for the rest of the session.
  defp demand(%{engine: :dead}), do: []
  defp demand(_state), do: [demand: {:input, 1}]

  defp infer(%{engine: :dead} = state, _buffer), do: {[], state}

  defp infer(%{stream: :open} = state, buffer) do
    case Host.push_au(state.host, state.camera.id, buffer.payload, buffer.pts, @time_base) do
      {:ok, {frames, _ended_tracks}} ->
        observe(%{state | pushed: state.pushed + 1}, frames)

      {:error, {reason, message}} when reason in @engine_fatal ->
        Logger.error(
          "camera #{state.camera.id}: detection stopped, engine is #{reason}: #{message}"
        )

        {[notify_parent: {:engine_fatal, reason}],
         %{state | engine: :dead, errors: state.errors + 1}}

      {:error, {reason, _message}} when reason in @stream_fatal ->
        # The host has already dropped the handle; the next AU reopens.
        {[], reopen_later(state)}

      {:error, :no_stream} ->
        {[], reopen_later(state)}

      {:error, _transient} ->
        {[], %{state | errors: state.errors + 1}}
    end
  end

  defp infer(state, _buffer), do: {[], state}

  defp observe(state, frames) do
    {observations, clock} =
      Observations.from_frames(
        state.clock,
        frames,
        state.camera.id,
        state.epoch,
        System.system_time(:millisecond)
      )

    # In this process, not the pipeline's: the sink is already the one blocked
    # in `push_au/5`, and routing through the parent would put the other
    # branches' notifications behind a tracker that is slow to start.
    Dispatch.forward_all(state.camera, state.policy, observations, tracker: state.tracker)

    {[], %{state | clock: clock}}
  end

  defp reopen_later(state) do
    %{state | stream: :closed, errors: state.errors + 1, retry_at: now_ms() + state.cooldown_ms}
  end

  defp ensure_stream(%{stream: :open} = state), do: state
  defp ensure_stream(%{engine: :dead} = state), do: state

  # Monotonic milliseconds, which start negative on the BEAM: nothing here may
  # read the value as a sign.
  defp ensure_stream(%{retry_at: retry_at} = state) when is_integer(retry_at) do
    if now_ms() >= retry_at, do: open(state), else: state
  end

  defp ensure_stream(state), do: open(state)

  defp open(state) do
    case Host.open_stream(state.host, state.camera.id, state.params) do
      {:ok, _epoch} ->
        %{state | stream: :open, retry_at: nil}

      {:error, reason} ->
        # Not fatal to the session: the engine may still be loading its model, and
        # the next AU past the cooldown tries again.
        Logger.warning(
          "camera #{state.camera.id}: no native detection stream (#{inspect(reason)})"
        )

        %{state | retry_at: now_ms() + state.cooldown_ms}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
