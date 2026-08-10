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
    * it does not judge its own health. `Cairn.Native.Health` does, from its own
      process, because this one can be inside a native call and a check running
      here cannot fire while it is. What is left here is answering that monitor's
      probe (`probe/1`) and reporting its verdict (`status/2`, `check_health/1`).

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
  indistinguishable from a stream that failed. Discriminating is
  `Cairn.Native.Health`'s job, and the evidence is cross-stream — every camera
  with traffic failing at once is the accelerator.
  """

  use GenServer

  require Logger

  alias Cairn.Config.Server, as: ConfigServer
  alias Cairn.Native.Canary
  alias Cairn.Native.Config, as: NativeConfig
  alias Cairn.Native.Health
  alias Cairn.StreamEpochs

  # How long an open waits for the same camera's pending native close. Under the
  # caller's own `GenServer.call` timeout on purpose: a close that is not coming
  # back should reach the caller as an error term, not as its exit.
  @close_wait_ms 2_000

  # The CPU baseline: enough passes for a median, and a bound on the whole
  # measurement — a second model load plus those passes, paid wherever the engine
  # opens, which is boot and a model reload that has already closed every stream.
  # Past the bound the node runs without a D-P5 ratio.
  @baseline_passes 5
  @baseline_timeout_ms 60_000

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
    :cpu_baseline_ms,
    engine_state: :starting,
    canary_state: :not_run,
    streams: %{},
    closing: %{}
  ]

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
        enter(stream, camera_id, System.monotonic_time(:microsecond))
        result = stream.module.push_au(stream.ref, au, pts, time_base)
        leave(stream)
        report(stream, camera_id, result)
        result

      :error ->
        {:error, :no_stream}
    end
  end

  @doc """
  Everything an operator or a status surface needs to know.

  Answered from the same mailbox the synchronous native calls queue in, so a
  caller that cannot afford to wait out one of those passes its own `timeout`
  and reads the expiry as `Cairn.Native.Status` does — as the wedge itself.
  """
  @spec status(atom(), timeout()) :: map()
  def status(server \\ __MODULE__, timeout \\ 5_000),
    do: GenServer.call(server, :status, timeout)

  @doc """
  Load a model, or replace the one loaded.

  Canary first, then `init/1`, then every stream that was open is reopened on the
  epoch its media session is still running under — each behind its own close, so a
  close still stuck in the crate costs that one camera its reopen. Blocks for a
  model load. This is the only recovery from an engine-fatal error: the other
  way in, `reconfigure/2`, does nothing for a config whose model has not moved,
  and a dead engine's has not.
  """
  @spec configure(atom(), map() | keyword(), timeout()) :: {:ok, map()} | {:error, term()}
  def configure(server \\ __MODULE__, config, timeout \\ 300_000) do
    GenServer.call(server, {:configure, config}, timeout)
  end

  @doc """
  Point the engine at the model a newly loaded `Cairn.Config` asks for.

  A no-op unless that model actually changed — an engine reload closes every
  stream and pays for a model load, which a reload that moved something else
  entirely must not spend. Asynchronous because the caller is
  `Cairn.Config.Server`, whose own reload must not wait on a model load; the
  work is `configure/3`'s, canary included.
  """
  @spec reconfigure(GenServer.server(), Cairn.Config.t()) :: :ok
  def reconfigure(server \\ __MODULE__, %Cairn.Config{} = config) do
    GenServer.cast(server, {:reconfigure, config})
  end

  @doc "Run `Cairn.Native.Health`'s check now, returning its verdict."
  @spec check_health(atom()) :: Health.verdict()
  def check_health(server \\ __MODULE__), do: Health.check(Health.name(server))

  @doc """
  The monitor's liveness probe.

  No deadline here: the caller is a throwaway task `Cairn.Native.Health` kills at
  its own, so that a Host inside a native call blocks nothing but this probe.
  """
  @spec probe(atom()) :: %{engine: term()}
  def probe(server), do: GenServer.call(server, :probe, :infinity)

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    table = Keyword.get(opts, :name, __MODULE__)
    :ets.new(table, [:named_table, :set, :protected, read_concurrency: true])

    # Public because the callers write it themselves, around a call this process is
    # deliberately not in (`enter/3`), and because `Cairn.Native.Health` reads it
    # and reaps the rows of callers that died mid-call.
    inflight = :"#{table}.inflight"
    :ets.new(inflight, [:named_table, :set, :public, write_concurrency: true])

    state = %__MODULE__{
      table: table,
      inflight: inflight,
      native: Keyword.get(opts, :native_module, Cairn.Native),
      canary: Keyword.get(opts, :canary_module, Canary),
      opts: opts
    }

    # The model load is seconds and the canary is another OS process: neither
    # belongs in a supervisor's start sequence.
    {:ok, state, {:continue, :open_engine}}
  end

  @impl true
  def handle_continue(:open_engine, state) do
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
    state = reload_engine(state, config)

    case state.engine_state do
      :ready -> {:reply, {:ok, status_map(state)}, state}
      other -> {:reply, {:error, other}, state}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, status_map(state), state}

  # Answered from the mailbox on purpose: it is the queue the synchronous native
  # calls above are in, so a reply is evidence that they are coming back. The
  # baseline rides along because the monitor cannot judge without it and the two
  # processes restart independently — every cycle re-reads it.
  def handle_call(:probe, _from, state) do
    {:reply, %{engine: state.engine_state, cpu_baseline_ms: state.cpu_baseline_ms}, state}
  end

  @impl true
  def handle_cast({:reconfigure, config}, state) do
    {:noreply, swap_model(state, configured_model(state, config))}
  end

  @impl true
  def handle_info({:inference, camera_id, token, {:error, reason, message}}, state) do
    {:noreply, note_error(state, camera_id, token, reason, message)}
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

  # In precedence order: a `:config` opt, the application env, then the profile
  # of whatever membrane camera the loaded config has. Only the third moves on a
  # reload, so a node whose model is pinned by an opt or the env stays pinned
  # through one.
  defp configured_model(state, config \\ nil) do
    with nil <- Keyword.get(state.opts, :config),
         nil <- Application.get_env(:cairn, __MODULE__, [])[:config] do
      profile_model(config || loaded_config(state))
    end
  end

  defp profile_model(config) do
    case Cairn.Config.native_model_config(config) do
      {:ok, model} ->
        model

      # Refused at config load too (`Cairn.Config`'s `validate_native_model/2`),
      # so reaching this is a config that never became the active one.
      {:error, message} ->
        Logger.error("cairn-native: " <> message)
        nil
    end
  end

  # Pulled once at startup rather than subscribed to: `Cairn.Config.Server`
  # starts before this process and pushes every later config through
  # `reconfigure/2`, which is the only path a *changed* profile takes.
  defp loaded_config(state) do
    Keyword.get(state.opts, :config_source, &ConfigServer.get/0).()
  end

  # `nil` is a config that says nothing about the model — an engine an opt or the
  # env pinned, or a node whose last membrane camera has gone.
  defp swap_model(state, nil), do: state

  defp swap_model(state, raw) do
    case NativeConfig.normalize(raw) do
      {:ok, config} ->
        if config == state.config, do: state, else: reload_engine(state, raw)

      {:error, message} ->
        # The running engine is kept: nothing about this reload reached it.
        Logger.error("cairn-native: reloaded config is not usable: #{message}")
        state
    end
  end

  # Every stream that was open comes back, on the epoch its media session is
  # still running under — but only behind a `:ready` engine, so a refused load
  # leaves them closed rather than reopening them against nothing.
  defp reload_engine(state, raw) do
    open = state.streams
    state = open_engine(close_streams(state), raw)

    if state.engine_state == :ready, do: reopen_streams(state, open), else: state
  end

  defp open_engine(state, nil) do
    # The normal state until a camera's profile is routed here.
    %{state | engine: nil, engine_state: :not_configured, cpu_baseline_ms: nil}
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

        %{
          state
          | engine: engine,
            engine_state: :ready,
            cpu_baseline_ms: measure_baseline(state, config)
        }

      {:error, {reason, message}} ->
        refuse(state, {reason, message}, "init/1 refused #{config.model}: #{reason} #{message}")

      other ->
        refuse(state, {:init_failed, other}, "init/1 answered #{inspect(other)}")
    end
  end

  defp refuse(state, engine_state, message) do
    Logger.error("cairn-native: " <> message)
    %{state | engine: nil, engine_state: engine_state, cpu_baseline_ms: nil}
  end

  # `Cairn.Native.Health` cannot judge an accelerator without knowing what one
  # model pass costs without it, and only this board and this model can say. In
  # a task, so a measurement that does not come back costs a bounded wait rather
  # than the engine: `nil` is the monitor's `:not_applicable`, which is where a
  # node with no number to compare against already sits.
  defp measure_baseline(state, config) do
    if NativeConfig.accelerator?(config), do: await_baseline(state, config), else: nil
  end

  defp await_baseline(state, config) do
    native = state.native
    passes = Keyword.get(state.opts, :baseline_passes, @baseline_passes)

    task =
      Task.Supervisor.async_nolink(Cairn.TaskSupervisor, fn ->
        native.cpu_baseline_ms(config, passes)
      end)

    timeout = Keyword.get(state.opts, :baseline_timeout_ms, @baseline_timeout_ms)

    # `ignore` rather than `shutdown` on expiry: a task inside a dirty NIF does
    # not die until the call returns, so a brutal kill would block on the very
    # thing that timed out. It stops monitoring and lets the task finish alone.
    case Task.yield(task, timeout) || Task.ignore(task) do
      {:ok, reply} -> baseline(reply, config)
      {:exit, reason} -> no_baseline(config, "the measurement crashed (#{inspect(reason)})")
      nil -> no_baseline(config, "the measurement did not answer in time")
    end
  end

  defp baseline({:ok, ms}, config) when is_number(ms) and ms > 0 do
    Logger.info(
      "cairn-native: CPU baseline #{Float.round(ms / 1, 2)} ms a pass for #{config.model} — " <>
        "#{config.backend} is judged against it"
    )

    ms / 1
  end

  # Zero and negative are not a pass anyone timed, and a baseline of zero would
  # put every accelerator under the ratio floor at once.
  defp baseline({:ok, ms}, config), do: no_baseline(config, "the measurement was #{inspect(ms)}")

  defp baseline({:error, {reason, message}}, config),
    do: no_baseline(config, "#{reason} #{message}")

  defp baseline(other, config), do: no_baseline(config, inspect(other))

  defp no_baseline(config, why) do
    Logger.warning(
      "cairn-native: no CPU baseline for #{config.model}: #{why} — #{config.backend} is loaded " <>
        "and detecting, but its health cannot be judged against the CPU"
    )

    nil
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
           %{
             ref: ref,
             token: token,
             module: state.native,
             host: self(),
             health: Health.name(state.table),
             inflight: state.inflight
           }}
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
  # which is what makes a hang evidence on its own (`Cairn.Native.Health.stalled/2`).
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
  #
  # `infer_us` and not the whole call: the call also paid a decode and a tensor
  # conversion, both backend-independent and together larger than an
  # accelerator's pass (`Stream::push_au`, `docs/npu-backends.md`). Against a CPU
  # baseline for the pass alone, that whole-call number reads a healthy
  # accelerator as under the D-P5 floor.
  #
  # Straight to the monitor: evidence routed through the process that can be
  # wedged is the thing the split undoes.
  defp report(stream, camera_id, {:ok, {frames, _ended_tracks}}) do
    {passes, micros} =
      Enum.reduce(frames, {0, 0}, fn
        %{inferred: true} = frame, {passes, micros} -> {passes + 1, micros + frame.infer_us}
        %{inferred: false}, counted -> counted
      end)

    if passes > 0,
      do: to_health(stream, {:inference, camera_id, {:passes, passes, micros}}),
      else: :ok
  end

  defp report(stream, camera_id, {:error, {reason, message}}) when is_atom(reason) do
    failed(stream, camera_id, reason, message)
  end

  defp report(stream, camera_id, other) do
    failed(stream, camera_id, :unknown, inspect(other))
  end

  # The only report both need, and for different things: the monitor counts it as
  # traffic, the host acts on the error class. Sent to each directly, so that
  # neither waits on the other to have read its mailbox.
  defp failed(stream, camera_id, reason, message) do
    to_health(stream, {:inference, camera_id, :failed})
    send(stream.host, {:inference, camera_id, stream.token, {:error, reason, message}})
    :ok
  end

  # By name, resolved per report: a monitor that restarted keeps being told, and one
  # that is not up costs this window a sample rather than the caller its call.
  defp to_health(stream, report) do
    case Process.whereis(stream.health) do
      nil -> :ok
      pid -> send(pid, report)
    end

    :ok
  end

  # -- status -----------------------------------------------------------------

  defp status_map(state) do
    Map.merge(
      %{
        nif: nif_status(state),
        engine: state.engine_state,
        canary: state.canary_state,
        model: state.config && state.config.model,
        backend: state.config && state.config.backend,
        streams: Map.keys(state.streams),
        # handle gone, native close not landed — what a reopen waits on
        closing: Map.keys(state.closing)
      },
      # Read out of the monitor's table, never called for: this process must not
      # wait on the one judging it, and `status/2` must answer before there has
      # been a monitor at all.
      Health.snapshot(state.table)
    )
  end

  defp nif_status(state) do
    case state.native.load_error() do
      nil -> :available
      reason -> {:unavailable, reason}
    end
  end
end
