defmodule Cairn.Native.Host do
  @moduledoc """
  Owns the in-VM detection engine: one NIF load, one model, one stream per
  camera.

  D-M3 as amended puts `cairn-native` on this node's dirty schedulers with no
  peer to contain it, so a panic in the stages is every camera on the box,
  recordings included. **This process is not that containment** — nothing in the
  BEAM is, and a supervisor above it buys nothing a panic respects. It is the
  policy that keeps the node from reaching the fault, and the lifecycle nobody
  else can own:

    * a new or changed model is probe-loaded in a throwaway OS process
      (`Cairn.Native.Canary`) before the in-VM NIF is allowed near it, model
      load being the known crash/wedge vector;
    * per-frame work runs in the **caller**, not here: `push_au/5` reads the
      stream handle out of ETS and calls the NIF itself, so one camera's 12 ms
      inference is not queued behind fifteen others and this process stays
      answerable while every one of them blocks;
    * NPU liveness is the D-P5 ratio and nothing else (spike 0.5): a wedged HTP
      still answers, at CPU speed, and survives `kill -9` and every restart
      above it — so a suspected wedge escalates to an operator alert and never
      to a restart loop.

  ## Where it sits

  A top-level `:one_for_one` child of `Cairn.Application`, after
  `Cairn.StreamEpochs` (whose epochs it announces under) and before
  `Cairn.CameraSupervisor` — like `Cairn.PluginGroupSupervisor`, what serves the
  cameras starts before the cameras do. Not under a camera's tree: the engine is
  one model for the whole VM, a camera restart must not reload it (seconds, and
  a multi-second HTP graph compile on QNN), and a camera crash must not cost
  every other camera its detector.

  Its own restart is cheap only because it holds no per-frame work, and it costs
  a model reload — which is why nothing here exits. A missing library, an
  unconfigured model, a refused canary, a failed `init/1` and a dead engine are
  all *states* this process reports rather than reasons for a supervisor to
  restart-loop on something no restart fixes.

  ## The two error classes

  The crate splits its reasons deliberately, and they are not remedied the same
  way. `config`, `open_stream`, `decode`, `infer`, `closed`, `poisoned` and
  `panicked` are **per stream**: the remedy is closing and reopening that one
  camera, which is the caller's to do (the ones that leave a stream unusable —
  `closed`, `poisoned`, `panicked` — have their handle dropped here, so the next
  `push_au/5` says `:no_stream` instead of running against state nobody knows
  the shape of). `model_load` and `model_poisoned` are **engine-fatal**: that
  engine handle can never serve any camera again, so it is dropped and only
  `configure/3` — canary first — brings one back.

  `infer` is the interesting one. From inside the crate it is per stream, and
  from inside the crate a wedged accelerator is indistinguishable from a stream
  that failed; the crate does not guess. Discriminating is this process's job
  and the evidence is **cross-stream**: one camera failing is that camera, every
  camera with traffic failing at once is the accelerator.

  ## Healthy, saturated, wedged, idle

  The NIF has no admission control. Once cameras × `sample_fps` passes what one
  model session sustains, the surplus is queueing time inside a `push_au/5` the
  caller is blocked in — so "healthy but slow" is a real state, and the ratio
  check must not report it as a wedge. What separates them is throughput: a
  saturated healthy accelerator still completes work at accelerator rate, and a
  wedged one cannot complete faster than the CPU it has silently fallen back to.
  """

  use GenServer

  require Logger

  alias Cairn.Native.Canary
  alias Cairn.Native.Config, as: NativeConfig
  alias Cairn.StreamEpochs

  @health_interval_ms 60_000
  # Below this the window is evidence of traffic, not of latency: a handful of
  # samples has no p50 worth escalating on.
  @health_min_samples 10
  # D-P5: an accelerator that is not at least this much faster than the CPU
  # baseline is not executing on the accelerator.
  @health_min_ratio 3.0
  # How close to accelerator-rate throughput still counts as accelerator-rate,
  # so that a saturated engine is not read as a wedged one over sampling noise.
  @health_throughput_slack 0.9
  # How many of one camera's latencies a window keeps; see `sampled/2`.
  @health_window 512

  @engine_fatal [:model_load, :model_poisoned]
  @stream_fatal [:closed, :poisoned, :panicked]

  defstruct [
    :table,
    :inflight,
    :native,
    :canary,
    :counters,
    :config,
    :engine,
    :opts,
    :checked_at,
    engine_state: :starting,
    canary_state: :not_run,
    streams: %{},
    window: %{},
    completed: 0,
    submitted: 0,
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

  `params` is `Cairn.Native.Config.stream_params/1`'s vocabulary — the
  operator-owned scene knobs (D-P6) and the media session's `stream_epoch`. The
  epoch is the *caller's*: it names the ffmpeg session the access units come
  from, and this process only says which one detections resume under. Reopening
  a camera that already has a stream closes the old one first.
  """
  @spec open_stream(atom(), String.t(), map() | keyword()) ::
          {:ok, Cairn.ULID.t()} | {:error, term()}
  def open_stream(server \\ __MODULE__, camera_id, params) do
    GenServer.call(server, {:open_stream, camera_id, params})
  end

  @spec close_stream(atom(), String.t()) :: :ok
  def close_stream(server \\ __MODULE__, camera_id) do
    GenServer.call(server, {:close_stream, camera_id})
  end

  @doc """
  Feed one access unit and take what it completed.

  Runs in the calling process and blocks it for as long as decode plus a model
  pass takes — and, under saturation, for as long as the streams ahead of it
  hold the model session too. That is the design
  (`plugins/cairn-native/src/lib.rs`), and it is why this call does not go
  through the GenServer.

  What comes back is one map per frame the access unit completed — none, one, or
  several — in the crate's own spelling. `Cairn.Native.Observations` is what
  turns them into `Cairn.Observation`s.
  """
  @spec push_au(atom(), String.t(), binary(), integer(), {integer(), integer()}) ::
          {:ok, {[map()], [String.t()]}} | {:error, term()}
  def push_au(server \\ __MODULE__, camera_id, au, pts, time_base) do
    case lookup(server, camera_id) do
      {:ok, stream} ->
        :counters.add(stream.counters, 1, 1)
        enter(stream, camera_id)
        started = System.monotonic_time(:microsecond)
        result = stream.module.push_au(stream.ref, au, pts, time_base)
        elapsed = System.monotonic_time(:microsecond) - started
        leave(stream)
        send(stream.host, {:inference, camera_id, elapsed, outcome(result)})
        result

      :error ->
        {:error, :no_stream}
    end
  end

  @doc "Everything an operator or task 3.4's status surface needs to know."
  @spec status(atom()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  Load a model, or replace the one loaded.

  Canary first, then `init/1`, then every stream that was open is reopened on
  the epoch its media session is still running under. Blocks for a model load,
  which on QNN is a graph compile. This is also the only recovery from an
  engine-fatal error.
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

    # Public because the callers write it themselves, on the frame path, around
    # a call this process is deliberately not in: see `enter/2`.
    inflight = :"#{table}.inflight"
    :ets.new(inflight, [:named_table, :set, :public, write_concurrency: true])

    state = %__MODULE__{
      table: table,
      inflight: inflight,
      native: Keyword.get(opts, :native_module, Cairn.Native),
      canary: Keyword.get(opts, :canary_module, Canary),
      # One counter for every stream: what it answers is whether *any* call went
      # in, and a per-stream counter would only be a per-stream answer to a
      # per-VM question.
      counters: :counters.new(1, [:write_concurrency]),
      checked_at: System.monotonic_time(:millisecond),
      opts: opts
    }

    # The model load is seconds and the canary is another OS process: neither
    # belongs in a supervisor's start sequence, which every later child waits on.
    {:ok, state, {:continue, :open_engine}}
  end

  @impl true
  def handle_continue(:open_engine, state) do
    schedule_health(state)
    {:noreply, open_engine(state, configured_model(state))}
  end

  @impl true
  def handle_call({:open_stream, camera_id, params}, _from, state) do
    case NativeConfig.stream_params(params) do
      {:ok, params} -> do_open_stream(state, camera_id, params)
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

  @impl true
  def handle_info({:inference, camera_id, micros, :ok}, state) do
    {:noreply, record(state, camera_id, &sampled(&1, micros))}
  end

  def handle_info({:inference, camera_id, _micros, {:error, reason, message}}, state) do
    state = record(state, camera_id, &%{&1 | errors: &1.errors + 1})
    {:noreply, note_error(state, camera_id, reason, message)}
  end

  def handle_info(:health_check, state) do
    schedule_health(state)
    {:noreply, run_health_check(state)}
  end

  # The canary's probe process is linked to this one while it runs; its exit,
  # anything it leaves behind, and any other stray, is not worth a restart that
  # would reload the model.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # A hardware decoder holds GPU surfaces until its stream closes, and a
    # shutdown that skipped this would leave them to the resource destructor's
    # timing rather than to now.
    close_streams(state)
    :ok
  end

  # -- engine lifecycle -------------------------------------------------------

  # SEAM (task 3.3): the model config arrives as a plain map here. When profile
  # expansion moves off argv, this is the one place that changes.
  defp configured_model(state) do
    Keyword.get(state.opts, :config) ||
      Application.get_env(:cairn, __MODULE__, [])[:config]
  end

  defp open_engine(state, nil) do
    # No model configured is the normal state until a camera's profile is routed
    # here (task 3.3). Nothing to say about it, and nothing to load.
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

  # `model_load` and `model_poisoned` say this engine handle can never serve any
  # camera again, so retrying anything against it is the one thing not to do:
  # every stream is closed and the handle dropped, and only `configure/3` —
  # which re-probes in a throwaway process first — brings an engine back.
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

  # `decode` and `infer` are per frame as often as they are per stream, and
  # `infer` is also what a wedged accelerator looks like from inside the crate.
  # Neither is acted on here: the health check is what has the cross-stream view
  # to tell one camera's failure from the accelerator's.
  defp note_error(state, _camera_id, _reason, _message), do: state

  # -- streams ----------------------------------------------------------------

  defp do_open_stream(%{engine_state: :ready} = state, camera_id, params) do
    state = drop_stream(state, camera_id)
    {epoch, origin} = resolve_epoch(camera_id, params)
    params = %{params | stream_epoch: epoch}

    case state.native.open_stream(state.engine, camera_id, params) do
      {:ok, ref} ->
        announce(camera_id, epoch, origin)

        :ets.insert(
          state.table,
          {camera_id,
           %{
             ref: ref,
             module: state.native,
             host: self(),
             counters: state.counters,
             inflight: state.inflight
           }}
        )

        {:reply, {:ok, epoch},
         %{state | streams: Map.put(state.streams, camera_id, %{ref: ref, params: params})}}

      {:error, {reason, message}} = error when reason in @engine_fatal ->
        {:reply, error, note_error(state, camera_id, reason, message)}

      {:error, _reason} = error ->
        Logger.error("cairn-native: opening #{camera_id}: #{inspect(error)}")
        {:reply, error, state}
    end
  end

  defp do_open_stream(state, _camera_id, _params) do
    {:reply, {:error, state.engine_state}, state}
  end

  defp drop_stream(state, camera_id) do
    case Map.pop(state.streams, camera_id) do
      {nil, _streams} ->
        state

      {stream, streams} ->
        :ets.delete(state.table, camera_id)
        state.native.close_stream(stream.ref)
        %{state | streams: streams}
    end
  end

  defp close_streams(state) do
    Enum.reduce(Map.keys(state.streams), state, &drop_stream(&2, &1))
  end

  # An engine reload leaves every camera's media session running and every one
  # of its streams dead, so they are reopened under the epoch they were already
  # on — the detector lost its history, the source did not. The re-announcement
  # is what tells a consumer which epoch detections resume under, exactly as
  # `Cairn.PluginGroupPort` re-announces from ETS after a respawn; a fresh ULID
  # here would retire an epoch the ring buffer's init segments already carry.
  defp reopen_streams(state, open) do
    Enum.reduce(open, state, fn {camera_id, stream}, state ->
      {:reply, _result, state} = do_open_stream(state, camera_id, stream.params)
      state
    end)
  end

  # The epoch is minted by whoever owns the media session — `Cairn.FFmpegPort`,
  # on every spawn. Only a camera nobody has minted for yet gets one from here,
  # and that is a `:started`: this process establishing the first session of a
  # camera's life is the one case where it is the authority.
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

  # A repeat of the epoch a consumer already holds is a no-op by
  # `Cairn.StreamEpochs`' own contract, so this is only ever information: it is
  # not sent for an epoch this process just minted (`new_epoch/3` broadcast that
  # one itself), and it never announces an epoch the mint side does not hold —
  # one no `current/1` agrees with is one no consumer should adopt.
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
    # the table dies with this process; a caller landing in the restart window
    # is told there is no stream rather than crashing with it.
    ArgumentError -> :error
  end

  # What "outstanding" is read off. The caller registers itself before the call
  # and clears itself after, so a caller killed mid-call leaves a row the health
  # check can tell from a live one. A lifetime submitted-minus-completed count
  # cannot: one killed caller inflates it forever, and every later idle window
  # then reads as `:wedged` — a page no restart clears, for nothing.
  defp enter(stream, camera_id) do
    :ets.insert(stream.inflight, {self(), camera_id})
    :ok
  rescue
    # the table dies with the host; a caller landing in the restart window still
    # gets its call made and answered, exactly as `lookup/2` intends
    ArgumentError -> :ok
  end

  defp leave(stream) do
    :ets.delete(stream.inflight, self())
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp outcome({:ok, _result}), do: :ok
  defp outcome({:error, {reason, message}}) when is_atom(reason), do: {:error, reason, message}
  defp outcome(other), do: {:error, :unknown, inspect(other)}

  # -- health -----------------------------------------------------------------

  defp schedule_health(state) do
    Process.send_after(
      self(),
      :health_check,
      health_opt(state, :interval_ms, @health_interval_ms)
    )
  end

  defp record(state, camera_id, fun) do
    entry = Map.get(state.window, camera_id, %{samples: [], count: 0, errors: 0})

    %{
      state
      | completed: state.completed + 1,
        window: Map.put(state.window, camera_id, fun.(entry))
    }
  end

  # Every completion is counted; only their latencies are capped, because the
  # p50 of the first few hundred of a window is the p50 of the window and the
  # counts are what the throughput arithmetic runs on.
  defp sampled(entry, micros) do
    samples = if entry.count >= @health_window, do: entry.samples, else: [micros | entry.samples]
    %{entry | samples: samples, count: entry.count + 1}
  end

  # The three-way discrimination the D-M3 risk row asks for, plus the fourth
  # state saturation makes real:
  #
  #   * nothing submitted and nothing completed -> :idle. No opinion, and it
  #     must not read as health.
  #   * nothing completed, nothing newly submitted, and calls still outstanding
  #     -> :wedged: a live caller is blocked inside the NIF (`inflight/1`).
  #     Requiring submissions to have stopped too is what keeps a window that
  #     merely ended mid-call from reading as a hang; a real hang answers the
  #     next window.
  #   * at least one stream completing normally -> :healthy. One camera erroring
  #     or crawling is that camera; the accelerator is demonstrably fine.
  #   * every stream with traffic failing or slow -> the accelerator. Slow is
  #     only a wedge if throughput says so too: a saturated healthy session
  #     still completes at accelerator rate, and a wedged one cannot beat the
  #     CPU it fell back to.
  defp run_health_check(state) do
    submitted = :counters.get(state.counters, 1)
    now = System.monotonic_time(:millisecond)

    window = %{
      submitted: submitted - state.submitted,
      completed: Enum.reduce(state.window, 0, fn {_id, e}, n -> n + e.count + e.errors end),
      # not a window count: a caller blocked inside the NIF is still registered
      # in every window it is stuck in
      outstanding: length(inflight(state)),
      elapsed_ms: max(now - state.checked_at, 1)
    }

    per_stream = Map.new(state.window, fn {id, entry} -> {id, classify(state, entry)} end)
    verdict = verdict(state, window, per_stream)

    state
    |> escalate(verdict, per_stream)
    |> Map.merge(%{
      submitted: submitted,
      checked_at: now,
      window: %{},
      health: verdict,
      stream_health: per_stream,
      p50_ms: window_p50(state)
    })
  end

  # The calls actually still in flight. A caller that died mid-call left its row
  # behind, and dropping it here is what keeps one killed camera process from
  # pinning every later idle window at `:wedged`. Every caller is on this node
  # (they hold an ETS-resident stream handle), so `Process.alive?/1` answers.
  defp inflight(state) do
    {live, dead} =
      state.inflight
      |> :ets.tab2list()
      |> Enum.split_with(fn {pid, _camera_id} -> Process.alive?(pid) end)

    Enum.each(dead, fn {pid, camera_id} ->
      Logger.debug("cairn-native: #{camera_id}'s caller #{inspect(pid)} died inside push_au/5")
      :ets.delete(state.inflight, pid)
    end)

    live
  end

  defp verdict(%{engine_state: :ready}, %{completed: 0, submitted: 0, outstanding: out}, _streams)
       when out > 0,
       do: :wedged

  defp verdict(%{engine_state: :ready}, %{completed: 0}, _streams), do: :idle

  defp verdict(%{engine_state: :ready} = state, window, streams) do
    cond do
      # A CPU backend has no accelerator to wedge, and no baseline to be three
      # times faster than.
      baseline(state) == nil -> :not_applicable
      Enum.any?(streams, &classified?(&1, :ok)) -> :healthy
      not Enum.any?(streams, &judged?/1) -> :idle
      Enum.all?(streams, &classified?(&1, :failing)) -> :wedged
      accelerator_rate?(state, window) -> :saturated
      true -> :wedged
    end
  end

  defp verdict(_state, _window, _streams), do: :unknown

  defp classified?({_camera_id, class}, class), do: true
  defp classified?({_camera_id, _class}, _other), do: false

  defp judged?({_camera_id, class}), do: class in [:slow, :failing]

  # `:unknown` rather than `:ok` below the sample floor: too few completions to
  # have a p50 is not evidence that this stream is well.
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

  # Throughput carries the D-P5 ratio when latency cannot: under saturation
  # every caller waits behind the others, so the p50 is queueing time, but the
  # session still retires work at accelerator rate. A wedged session cannot —
  # its ceiling is the CPU's.
  defp accelerator_rate?(state, window) do
    cpu_rate = 1000 / baseline(state)
    observed = window.completed * 1000 / window.elapsed_ms
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
      health: state.health,
      stream_health: state.stream_health,
      p50_ms: state.p50_ms,
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
