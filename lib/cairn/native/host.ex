defmodule Cairn.Native.Host do
  @moduledoc """
  Owns the in-VM detection engine: one NIF load, one model, one stream per
  camera.

  Nothing in the BEAM contains a panic in the stages, so this process is the
  policy that keeps the node from reaching one:

    * a new or changed model is probe-loaded in a throwaway OS process
      (`Cairn.Native.Canary`) before the in-VM NIF is allowed near it;
    * per-frame work runs in the caller, not here: `push_au/5` reads the stream
      handle out of ETS and calls the NIF itself, so this process stays
      answerable while every camera blocks. Native teardown is in a supervised
      task for the same reason (`close_natively/3`);
    * NPU liveness is the D-P5 ratio and nothing else (spike 0.5): a wedged HTP
      still answers, at CPU speed, and survives `kill -9` and every restart
      above it — so a suspected wedge escalates to an operator alert and never
      to a restart loop.

  Nothing here exits: a missing library, an unconfigured model, a refused canary,
  a failed `init/1` and a dead engine are all states it reports. Nor does it sit
  under a camera's tree — a camera restart must not reload the model (a
  multi-second HTP graph compile on QNN), and a camera crash must not cost every
  other camera its detector.

  ## The two error classes

  The per-stream reasons are the caller's to remedy by reopening; the three that
  leave a stream unusable (`@stream_fatal`) have their handle dropped here, so the
  next `push_au/5` says `:no_stream` rather than running against state nobody
  knows the shape of. `model_load` and `model_poisoned` are engine-fatal: that
  handle can never serve any camera again, and only `configure/3` — canary first —
  brings one back.

  `infer` is the interesting one: inside the crate a wedged accelerator is
  indistinguishable from a stream that failed. Discriminating is this process's
  job, and the evidence is cross-stream — every camera with traffic failing at
  once is the accelerator.

  ## Healthy, saturated, wedged, idle

  The NIF has no admission control, so once cameras × `sample_fps` passes what one
  session sustains the surplus is queueing time inside a `push_au/5` and "healthy
  but slow" is a real state the ratio check must not call a wedge. Throughput is
  what separates them: a saturated healthy accelerator still retires work at
  accelerator rate, and a wedged one cannot beat the CPU it fell back to.

  Both are measured on completed model passes alone — most calls return without
  running the model, and a failed pass had no accelerator in it either.
  """

  use GenServer

  require Logger

  alias Cairn.Native.Canary
  alias Cairn.Native.Config, as: NativeConfig
  alias Cairn.StreamEpochs

  @health_interval_ms 60_000
  # Below this a window is evidence of traffic, not of latency: too few samples for
  # a p50 worth escalating on.
  @health_min_samples 10
  # D-P5: an accelerator not at least this much faster than the CPU baseline is not
  # executing on the accelerator.
  @health_min_ratio 3.0
  # How close to accelerator-rate throughput still counts as accelerator-rate, so
  # that sampling noise does not read a saturated engine as a wedged one.
  @health_throughput_slack 0.9
  # How many of one camera's latencies a window keeps; see `sampled/3`.
  @health_window 512

  # How long an open waits for the same camera's pending native close. Under the
  # caller's own `GenServer.call` timeout on purpose: a close that is not coming
  # back should reach the caller as an error term, not as its exit.
  @close_wait_ms 2_000

  @engine_fatal [:model_load, :model_poisoned]
  @stream_fatal [:closed, :poisoned, :panicked]

  defstruct [
    :table,
    :inflight,
    :native,
    :canary,
    :config,
    :engine,
    :opts,
    :checked_at,
    engine_state: :starting,
    canary_state: :not_run,
    streams: %{},
    closing: %{},
    window: %{},
    completed: 0,
    health: :unknown,
    stream_health: %{},
    p50_ms: nil
  ]

  @type health :: :unknown | :not_applicable | :idle | :healthy | :saturated | :wedged

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Open `camera_id`'s stream, returning the epoch its detections belong to.

  `params` is `Cairn.Native.Config.stream_params/1`'s vocabulary. The epoch is the
  *caller's*: it names the ffmpeg session the access units come from.

  Reopening a camera that already has a stream closes the old one first and waits
  for that close to reach the crate, which holds the camera id until it does.
  `{:error, {:closing, message}}` is that wait giving up, and there is nothing the
  caller can do about it: a `push_au/5` wedged in the NIF holds the teardown off
  indefinitely, and no second stream for this camera is possible until it lands.
  """
  @spec open_stream(atom(), String.t(), map() | keyword()) ::
          {:ok, Cairn.ULID.t()} | {:error, term()}
  def open_stream(server \\ __MODULE__, camera_id, params) do
    GenServer.call(server, {:open_stream, camera_id, params})
  end

  @doc """
  Drop `camera_id`'s stream.

  The handle is gone when this returns — no later `push_au/5` finds it — but the
  crate's own teardown is still outstanding, and only when it lands is the camera
  id free to be opened again.
  """
  @spec close_stream(atom(), String.t()) :: :ok
  def close_stream(server \\ __MODULE__, camera_id) do
    GenServer.call(server, {:close_stream, camera_id})
  end

  @doc """
  Feed one access unit and take what it completed.

  Blocks the caller for decode plus a model pass — and, under saturation, for as
  long as the streams ahead of it hold the model session too.

  The frames come back in the crate's own spelling; `Cairn.Native.Observations`
  turns them into `Cairn.Observation`s.
  """
  @spec push_au(atom(), String.t(), binary(), integer(), {integer(), integer()}) ::
          {:ok, {[map()], [String.t()]}} | {:error, term()}
  def push_au(server \\ __MODULE__, camera_id, au, pts, time_base) do
    case lookup(server, camera_id) do
      {:ok, stream} ->
        started = System.monotonic_time(:microsecond)
        enter(stream, camera_id, started)
        result = stream.module.push_au(stream.ref, au, pts, time_base)
        elapsed = System.monotonic_time(:microsecond) - started
        leave(stream)
        report(stream, camera_id, elapsed, result)
        result

      :error ->
        {:error, :no_stream}
    end
  end

  @doc "Everything an operator or a status surface needs to know."
  @spec status(atom()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  Load a model, or replace the one loaded.

  Canary first, then `init/1`, then every stream that was open is reopened on the
  epoch its media session is still running under — each behind its own close, so a
  close still stuck in the crate costs that one camera its reopen. Blocks for a
  model load. This is the only recovery from an engine-fatal error.
  """
  @spec configure(atom(), map() | keyword(), timeout()) :: {:ok, map()} | {:error, term()}
  def configure(server \\ __MODULE__, config, timeout \\ 300_000) do
    GenServer.call(server, {:configure, config}, timeout)
  end

  @doc "Run the periodic health check now, returning its verdict."
  @spec check_health(atom()) :: health()
  def check_health(server \\ __MODULE__), do: GenServer.call(server, :check_health)

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    table = Keyword.get(opts, :name, __MODULE__)
    :ets.new(table, [:named_table, :set, :protected, read_concurrency: true])

    # Public because the callers write it themselves, around a call this process is
    # deliberately not in: see `enter/3`.
    inflight = :"#{table}.inflight"
    :ets.new(inflight, [:named_table, :set, :public, write_concurrency: true])

    state = %__MODULE__{
      table: table,
      inflight: inflight,
      native: Keyword.get(opts, :native_module, Cairn.Native),
      canary: Keyword.get(opts, :canary_module, Canary),
      checked_at: System.monotonic_time(:microsecond),
      opts: opts
    }

    # The model load is seconds and the canary is another OS process: neither
    # belongs in a supervisor's start sequence.
    {:ok, state, {:continue, :open_engine}}
  end

  @impl true
  def handle_continue(:open_engine, state) do
    schedule_health(state)
    {:noreply, open_engine(state, configured_model(state))}
  end

  @impl true
  def handle_call({:open_stream, camera_id, params}, from, state) do
    case NativeConfig.stream_params(params) do
      {:ok, params} -> {:noreply, open_or_park(state, camera_id, params, from)}
      {:error, message} -> {:reply, {:error, {:config, message}}, state}
    end
  end

  def handle_call({:close_stream, camera_id}, _from, state) do
    {:reply, :ok, drop_stream(state, camera_id)}
  end

  def handle_call({:configure, config}, _from, state) do
    open = state.streams
    state = open_engine(close_streams(state), config)

    case state.engine_state do
      :ready -> {:reply, {:ok, status_map(state)}, reopen_streams(state, open)}
      other -> {:reply, {:error, other}, state}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, status_map(state), state}

  def handle_call(:check_health, _from, state) do
    state = run_health_check(state)
    {:reply, state.health, state}
  end

  # A completed pass is the engine's work whichever open it belonged to, so the
  # window takes it untokened; only reports that act on stream identity are gated
  # on the token (`note_error/5`).
  @impl true
  def handle_info({:inference, camera_id, _token, {:passes, passes, micros}}, state) do
    {:noreply, record(state, camera_id, passes, &sampled(&1, micros, passes))}
  end

  def handle_info({:inference, camera_id, token, {:error, reason, message}}, state) do
    # Traffic, never work retired (`run_health_check/1`): a stream doing nothing but
    # erroring must reach the cross-stream verdict rather than read as silence.
    state = record(state, camera_id, 0, &%{&1 | errors: &1.errors + 1})
    {:noreply, note_error(state, camera_id, token, reason, message)}
  end

  def handle_info(:health_check, state) do
    schedule_health(state)
    {:noreply, run_health_check(state)}
  end

  # A close task's exit, returned or crashed: either way there is nothing further
  # for an open parked behind it to wait on.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.closing, fn {_camera_id, closing} -> closing.ref == ref end) do
      nil ->
        {:noreply, state}

      {camera_id, closing} ->
        state = %{state | closing: Map.delete(state.closing, camera_id)}
        {:noreply, resume(state, camera_id, closing.parked)}
    end
  end

  # The ref is what makes a timer nobody cancelled harmless: it matches only the
  # close this one was armed for, and only while that close is still parked on.
  def handle_info({:close_timeout, camera_id, ref}, state) do
    case Map.get(state.closing, camera_id) do
      %{ref: ^ref, parked: {from, _params}} = closing ->
        # Logged as well as replied: an engine reload's reopen parks with no caller
        # to tell, and it is a camera left without a detector.
        Logger.warning("cairn-native: #{still_closing(camera_id)}; it is not being reopened")
        reply(from, {:error, {:closing, still_closing(camera_id)}})

        {:noreply,
         %{state | closing: Map.put(state.closing, camera_id, %{closing | parked: nil})}}

      _landed ->
        {:noreply, state}
    end
  end

  # The canary's probe process is linked to this one while it runs; its exit, and
  # any other stray, is not worth a restart that would reload the model.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # A hardware decoder holds GPU surfaces until its stream closes, so a shutdown
    # must not leave them to the destructor's timing. The closes go to tasks under
    # `Cairn.TaskSupervisor` — started before this process, so shut down after it —
    # rather than out of this call's shutdown budget, which one stream wedged in
    # `push_au/5` would exhaust on its own.
    close_streams(state)
    :ok
  end

  # -- engine lifecycle -------------------------------------------------------

  # The seam for profile expansion: when it moves off argv, the model config still
  # arrives as a plain map here and this is the one place that changes.
  defp configured_model(state) do
    Keyword.get(state.opts, :config) ||
      Application.get_env(:cairn, __MODULE__, [])[:config]
  end

  defp open_engine(state, nil) do
    # The normal state until a camera's profile is routed here.
    %{state | engine: nil, engine_state: :not_configured}
  end

  defp open_engine(state, raw) do
    case NativeConfig.normalize(raw) do
      {:ok, config} -> canary_then_load(%{state | config: config}, config)
      {:error, message} -> refuse(state, {:config, message}, "config is not usable: #{message}")
    end
  end

  defp canary_then_load(state, config) do
    if state.native.available?() do
      probe(state, config)
    else
      refuse(
        state,
        {:nif_unavailable, state.native.load_error()},
        "cairn-native is not loaded (#{inspect(state.native.load_error())}); " <>
          "no camera on this node will be detected on"
      )
    end
  end

  defp probe(state, config) do
    case state.canary.probe(config, canary_opts(state)) do
      :ok ->
        load_model(state, config, :passed)

      {:skipped, why} ->
        load_model(state, config, {:skipped, why})

      {:error, message} ->
        refuse(
          %{state | canary_state: {:failed, message}},
          {:canary_failed, message},
          "canary refused #{config.model}: #{message} — the model was NOT loaded in this VM"
        )
    end
  end

  defp load_model(state, config, canary) do
    state = %{state | canary_state: canary}

    case state.native.init(config) do
      {:ok, engine} ->
        Logger.info(
          "cairn-native: engine ready — model #{config.model} backend #{config.backend} " <>
            "(canary #{inspect(canary)})"
        )

        %{state | engine: engine, engine_state: :ready}

      {:error, {reason, message}} ->
        refuse(state, {reason, message}, "init/1 refused #{config.model}: #{reason} #{message}")

      other ->
        refuse(state, {:init_failed, other}, "init/1 answered #{inspect(other)}")
    end
  end

  defp refuse(state, engine_state, message) do
    Logger.error("cairn-native: " <> message)
    %{state | engine: nil, engine_state: engine_state}
  end

  defp canary_opts(state) do
    state.opts
    |> Keyword.get(:canary, [])
    |> Keyword.merge(Application.get_env(:cairn, Canary, []))
  end

  # Token-gated, because a reopen can complete before the retired caller is
  # scheduled to report, and that report would then close the replacement — a camera
  # going dark for a fault it never had. Engine-fatal reasons need no gate: every
  # stream goes with the handle.
  defp note_error(state, camera_id, token, reason, message) when reason in @stream_fatal do
    case Map.get(state.streams, camera_id) do
      %{token: ^token} ->
        note_error(state, camera_id, reason, message)

      _retired ->
        Logger.debug(
          "cairn-native: #{reason} on #{camera_id} is from an open that is already closed"
        )

        state
    end
  end

  defp note_error(state, camera_id, _token, reason, message),
    do: note_error(state, camera_id, reason, message)

  defp note_error(state, camera_id, reason, message) when reason in @engine_fatal do
    Logger.error(
      "cairn-native: #{reason} on #{camera_id}: #{message} — the engine is dead for every " <>
        "camera; a fresh init behind the canary is the only recovery"
    )

    %{close_streams(state) | engine: nil, engine_state: {reason, message}}
  end

  defp note_error(state, camera_id, reason, message) when reason in @stream_fatal do
    Logger.error("cairn-native: #{reason} on #{camera_id}: #{message} — closing that stream")
    drop_stream(state, camera_id)
  end

  # `decode` and `infer` are per frame as often as per stream, so neither is acted on
  # here: only the health check has the cross-stream view to tell one camera's
  # failure from the accelerator's.
  defp note_error(state, _camera_id, _reason, _message), do: state

  # -- streams ----------------------------------------------------------------

  # An open waits for the camera's pending native close rather than racing it: the
  # crate holds the camera id until that close hands it back, so an open that
  # overtook one would be refused as a duplicate. The wait's expiry is the honest
  # answer and not a retry — nothing here can hurry a close the crate is inside.
  defp open_or_park(state, camera_id, params, from) do
    state = drop_stream(state, camera_id)

    case Map.fetch(state.closing, camera_id) do
      :error ->
        {result, state} = do_open_stream(state, camera_id, params)
        reply(from, result)
        state

      {:ok, %{parked: nil} = closing} ->
        park(state, camera_id, closing, from, params)

      # One waiter per camera: only one of two could have the stream it asks for.
      {:ok, _taken} ->
        reply(from, {:error, {:closing, still_closing(camera_id)}})
        state
    end
  end

  defp park(state, camera_id, closing, from, params) do
    Process.send_after(
      self(),
      {:close_timeout, camera_id, closing.ref},
      Keyword.get(state.opts, :close_wait_ms, @close_wait_ms)
    )

    %{state | closing: Map.put(state.closing, camera_id, %{closing | parked: {from, params}})}
  end

  defp resume(state, _camera_id, nil), do: state

  defp resume(state, camera_id, {from, params}),
    do: open_or_park(state, camera_id, params, from)

  # `nil` is `reopen_streams/2`, which opens on nobody's behalf.
  defp reply(nil, _result), do: :ok
  defp reply(from, result), do: GenServer.reply(from, result)

  defp still_closing(camera_id) do
    "#{camera_id}'s native close has not returned, and the crate holds its camera id until " <>
      "it does — either a push is wedged inside the NIF or a decoder teardown is still in " <>
      "the driver"
  end

  defp do_open_stream(%{engine_state: :ready} = state, camera_id, params) do
    {epoch, origin} = resolve_epoch(camera_id, params)
    params = %{params | stream_epoch: epoch}

    case state.native.open_stream(state.engine, camera_id, params) do
      {:ok, ref} ->
        announce(camera_id, epoch, origin)
        # Names this open, so a report from a push the reopen raced past is not
        # mistaken for one about the stream the camera has now.
        token = System.unique_integer([:positive, :monotonic])

        :ets.insert(
          state.table,
          {camera_id,
           %{ref: ref, token: token, module: state.native, host: self(), inflight: state.inflight}}
        )

        {{:ok, epoch},
         %{
           state
           | streams: Map.put(state.streams, camera_id, %{ref: ref, token: token, params: params})
         }}

      {:error, {reason, message}} = error when reason in @engine_fatal ->
        {error, note_error(state, camera_id, reason, message)}

      {:error, _reason} = error ->
        Logger.error("cairn-native: opening #{camera_id}: #{inspect(error)}")
        {error, state}
    end
  end

  defp do_open_stream(state, _camera_id, _params) do
    {{:error, state.engine_state}, state}
  end

  defp drop_stream(state, camera_id) do
    case Map.pop(state.streams, camera_id) do
      {nil, _streams} ->
        state

      {stream, streams} ->
        # Both before the native close, and both synchronously: a caller must find
        # the stream gone the moment this returns, however long the close takes.
        :ets.delete(state.table, camera_id)
        state = %{state | streams: streams}

        case close_natively(state, camera_id, stream) do
          {:ok, ref} ->
            %{state | closing: Map.put(state.closing, camera_id, %{ref: ref, parked: nil})}

          :error ->
            state
        end
    end
  end

  # The native close waits on the mutex a `push_au/5` holds for its whole call, so it
  # is made anywhere but here — under the application's task supervisor, which
  # outlives this process and so carries a `terminate/2` close past its shutdown.
  defp close_natively(state, camera_id, stream) do
    native = state.native

    case Task.Supervisor.start_child(Cairn.TaskSupervisor, fn ->
           native.close_stream(stream.ref)
         end) do
      {:ok, pid} ->
        {:ok, Process.monitor(pid)}

      {:error, reason} ->
        # Not closed inline instead: blocking this process is what is being avoided,
        # and the handle's destructor frees the decoder and the camera id when the
        # BEAM collects it — later than now, but not never.
        Logger.error(
          "cairn-native: no task to close #{camera_id} on (#{inspect(reason)}); its decoder " <>
            "and its camera id wait for the handle to be collected"
        )

        :error
    end
  end

  defp close_streams(state) do
    Enum.reduce(Map.keys(state.streams), state, &drop_stream(&2, &1))
  end

  # An engine reload leaves every media session running, so streams are reopened
  # under the epoch they were already on: the detector lost its history, the source
  # did not, and a fresh ULID would retire an epoch the ring buffer's init segments
  # already carry.
  defp reopen_streams(state, open) do
    Enum.reduce(open, state, fn {camera_id, stream}, state ->
      open_or_park(state, camera_id, stream.params, nil)
    end)
  end

  # The epoch is minted by whoever owns the media session — `Cairn.FFmpegPort`, on
  # every spawn. Only a camera nobody has minted for yet gets one from here: this
  # process establishing the first session of a camera's life is the one case where
  # it is the authority.
  defp resolve_epoch(camera_id, params) do
    case params.stream_epoch || current_epoch(camera_id) do
      nil -> {StreamEpochs.new_epoch(camera_id, :started), :minted}
      epoch -> {epoch, :adopted}
    end
  end

  defp current_epoch(camera_id) do
    case StreamEpochs.current(camera_id) do
      {:ok, epoch} -> epoch
      :unknown -> nil
    end
  end

  # Not sent for an epoch this process just minted (`new_epoch/3` broadcast that
  # one), and never for one `current/1` does not agree with.
  defp announce(_camera_id, _epoch, :minted), do: :ok

  defp announce(camera_id, epoch, :adopted) do
    if current_epoch(camera_id) == epoch do
      Phoenix.PubSub.local_broadcast(
        Cairn.PubSub,
        StreamEpochs.topic(),
        {:stream_epoch, camera_id, epoch, :started}
      )
    end

    :ok
  end

  defp lookup(table, camera_id) do
    case :ets.lookup(table, camera_id) do
      [{^camera_id, stream}] -> {:ok, stream}
      [] -> :error
    end
  rescue
    # the table dies with this process; a caller landing in the restart window is
    # told there is no stream rather than crashing with it
    ArgumentError -> :error
  end

  # A row rather than a submitted-minus-completed count: one caller killed mid-call
  # would inflate such a count forever and pin every later idle window at `:wedged`.
  # A row can be told from a live caller's, and it carries when the call went in,
  # which is what makes a hang evidence on its own (`stalled/2`).
  defp enter(stream, camera_id, started) do
    :ets.insert(stream.inflight, {self(), camera_id, stream.token, started})
    :ok
  rescue
    # as `lookup/2`: the caller still gets its call made and answered
    ArgumentError -> :ok
  end

  defp leave(stream) do
    :ets.delete(stream.inflight, self())
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Only frames the model really ran on: counting one the motion gate skipped would
  # read the D-P5 ratio off a call the accelerator was never in. A frame with no
  # `inferred` raises rather than reading as a call that ran no model, which would be
  # the health check going blind.
  defp report(stream, camera_id, elapsed, {:ok, {frames, _ended_tracks}}) do
    case Enum.count(frames, & &1.inferred) do
      0 -> :ok
      passes -> notify(stream, camera_id, {:passes, passes, elapsed})
    end
  end

  defp report(stream, camera_id, _elapsed, {:error, {reason, message}}) when is_atom(reason) do
    notify(stream, camera_id, {:error, reason, message})
  end

  defp report(stream, camera_id, _elapsed, other) do
    notify(stream, camera_id, {:error, :unknown, inspect(other)})
  end

  defp notify(stream, camera_id, report) do
    send(stream.host, {:inference, camera_id, stream.token, report})
    :ok
  end

  # -- health -----------------------------------------------------------------

  defp schedule_health(state) do
    Process.send_after(
      self(),
      :health_check,
      health_opt(state, :interval_ms, @health_interval_ms)
    )
  end

  defp record(state, camera_id, completed, fun) do
    entry = Map.get(state.window, camera_id, %{samples: [], count: 0, errors: 0})

    %{
      state
      | completed: state.completed + completed,
        window: Map.put(state.window, camera_id, fun.(entry))
    }
  end

  # Every pass is counted and only the latencies are capped: the p50 of the first few
  # hundred is the p50 of the window, while the counts are what the throughput
  # arithmetic runs on. Dividing by `passes` keeps the sample a per-frame latency
  # even though one call carries at most one pass today, which is the only thing a
  # per-frame CPU baseline can be compared against.
  defp sampled(entry, micros, passes) do
    sample = div(micros, passes)
    samples = if entry.count >= @health_window, do: entry.samples, else: [sample | entry.samples]
    %{entry | samples: samples, count: entry.count + passes}
  end

  # `traffic` (passes and failures alike) is whether anything is happening at all;
  # `retired` (completed passes) is whether the accelerator is executing — an error
  # proves the first and never the second.
  #
  #   * no pass came back -> :idle, unless a call has been in flight since before
  #     this window, whose own age is evidence of a live caller blocked inside the
  #     NIF (`stalled/2`) -> :wedged instead.
  #   * a stream with traffic nobody can judge yet -> :unknown, because the
  #     expensive direction is the false page.
  #   * every stream with traffic failing or slow -> the accelerator, unless retired
  #     throughput is still at accelerator rate -> :saturated instead.
  defp run_health_check(state) do
    now = System.monotonic_time(:microsecond)

    {retired, errors} =
      Enum.reduce(state.window, {0, 0}, fn {_id, e}, {retired, errors} ->
        {retired + e.count, errors + e.errors}
      end)

    window = %{
      retired: retired,
      traffic: retired + errors,
      # not a window count: a caller blocked inside the NIF is still registered
      # in every window it is stuck in
      stalled: length(stalled(inflight(state), state.checked_at)),
      elapsed_ms: max(div(now - state.checked_at, 1000), 1)
    }

    per_stream = Map.new(state.window, fn {id, entry} -> {id, classify(state, entry)} end)
    verdict = verdict(state, window, per_stream)

    state
    |> escalate(verdict, per_stream)
    |> Map.merge(%{
      checked_at: now,
      window: %{},
      health: verdict,
      stream_health: per_stream,
      p50_ms: window_p50(state)
    })
  end

  # Dropping the rows of callers that died mid-call is what keeps one killed camera
  # process from pinning every later idle window at `:wedged`. Every caller is on
  # this node, so `Process.alive?/1` answers.
  defp inflight(state) do
    {live, dead} =
      state.inflight
      |> :ets.tab2list()
      |> Enum.split_with(fn {pid, _camera_id, _token, _started_at} -> Process.alive?(pid) end)

    Enum.each(dead, fn {pid, camera_id, token, _started_at} ->
      Logger.debug(
        "cairn-native: #{camera_id}'s caller #{inspect(pid)} died inside push_au/5 (open #{token})"
      )

      :ets.delete(state.inflight, pid)
    end)

    live
  end

  # A call that went in *during* the window is unfinished, not slow, which keeps a
  # window that merely ended mid-call from reading as a hang; a real hang is still
  # there for the next one. Both clocks are microseconds because at millisecond
  # resolution a call entered in the tick the window opened in never becomes stalled.
  defp stalled(inflight, window_start) do
    Enum.filter(inflight, fn {_pid, _camera_id, _token, started_at} ->
      started_at < window_start
    end)
  end

  defp verdict(%{engine_state: :ready}, %{traffic: 0, stalled: stalled}, _streams)
       when stalled > 0,
       do: :wedged

  defp verdict(%{engine_state: :ready}, %{traffic: 0}, _streams), do: :idle

  defp verdict(%{engine_state: :ready} = state, window, streams) do
    cond do
      # A CPU backend has no accelerator to wedge, and no baseline to be three
      # times faster than.
      baseline(state) == nil -> :not_applicable
      Enum.any?(streams, &classified?(&1, :ok)) -> :healthy
      not Enum.any?(streams, &judged?/1) -> :idle
      Enum.any?(streams, &classified?(&1, :unknown)) -> :unknown
      Enum.all?(streams, &classified?(&1, :failing)) -> :wedged
      accelerator_rate?(state, window) -> :saturated
      true -> :wedged
    end
  end

  defp verdict(_state, _window, _streams), do: :unknown

  defp classified?({_camera_id, class}, class), do: true
  defp classified?({_camera_id, _class}, _other), do: false

  defp judged?({_camera_id, class}), do: class in [:slow, :failing]

  # `:unknown` rather than `:ok` below the sample floor: too few completions for a
  # p50 is not evidence either way, which is why one of these suspends the
  # cross-stream call.
  defp classify(_state, %{count: 0, errors: errors}) when errors > 0, do: :failing

  defp classify(state, entry) do
    cond do
      baseline(state) == nil -> :unknown
      entry.count < health_opt(state, :min_samples, @health_min_samples) -> :unknown
      # microsecond resolution: a call that measured zero is not a ratio, it is
      # faster than this clock can say, which is not what a wedge looks like
      percentile_ms(entry.samples, 0.5) == 0.0 -> :ok
      baseline(state) / percentile_ms(entry.samples, 0.5) >= min_ratio(state) -> :ok
      true -> :slow
    end
  end

  # Throughput carries the D-P5 ratio when latency cannot: under saturation the p50 is
  # queueing time, but the session still retires work at accelerator rate and a
  # wedged one cannot.
  #
  # Retired passes only, never `window.traffic`: a failed pass comes back at whatever
  # rate the failure is raised at, so one stream erroring in a tight loop would clear
  # this floor on its own and report a wedge as saturation.
  defp accelerator_rate?(state, window) do
    cpu_rate = 1000 / baseline(state)
    observed = window.retired * 1000 / window.elapsed_ms
    observed >= min_ratio(state) * cpu_rate * @health_throughput_slack
  end

  defp escalate(%{health: :wedged} = state, :wedged, _streams), do: state

  defp escalate(state, :wedged, streams) do
    Logger.error(
      "cairn-native: NPU health check FAILED — every stream with traffic is failing, or is " <>
        "under the #{min_ratio(state)}× D-P5 floor against a #{baseline(state)} ms CPU " <>
        "baseline with no throughput to explain it as saturation (#{inspect(streams)}). " <>
        "Restarting does not clear a wedged accelerator (spike 0.5: it survives kill -9), so " <>
        "this host will not restart itself — the board needs an operator."
    )

    state
  end

  defp escalate(%{health: :wedged} = state, verdict, _streams) do
    Logger.warning("cairn-native: NPU health recovered to #{verdict}")
    state
  end

  defp escalate(state, _verdict, _streams), do: state

  defp window_p50(state) do
    case Enum.flat_map(state.window, fn {_id, entry} -> entry.samples end) do
      [] -> nil
      samples -> percentile_ms(samples, 0.5)
    end
  end

  defp percentile_ms(samples, fraction) do
    sorted = Enum.sort(samples)
    index = min(trunc(length(sorted) * fraction), length(sorted) - 1)
    Enum.at(sorted, index) / 1000
  end

  defp baseline(state), do: health_opt(state, :cpu_baseline_ms, nil)
  defp min_ratio(state), do: health_opt(state, :min_ratio, @health_min_ratio)

  defp health_opt(state, key, default) do
    state.opts |> Keyword.get(:health, []) |> Keyword.get(key, default)
  end

  defp status_map(state) do
    %{
      nif: nif_status(state),
      engine: state.engine_state,
      canary: state.canary_state,
      model: state.config && state.config.model,
      backend: state.config && state.config.backend,
      streams: Map.keys(state.streams),
      # handle gone, native close not landed — what a reopen waits on
      closing: Map.keys(state.closing),
      health: state.health,
      stream_health: state.stream_health,
      p50_ms: state.p50_ms,
      # model passes, not `push_au/5` calls: at 5 fps sampled off a 20 fps camera the
      # two differ by the frame rate
      inferences: state.completed
    }
  end

  defp nif_status(state) do
    case state.native.load_error() do
      nil -> :available
      reason -> {:unavailable, reason}
    end
  end
end
