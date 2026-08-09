defmodule Cairn.Native.Health do
  @moduledoc """
  Judges the accelerator from outside the process that owns it.

  The rule that makes the split correct rather than merely different: a wedged
  subject must make this check *fail*, never make it *not run*
  (`research/ex-nvr-native-patterns.md` §6). Nothing here holds the engine, a
  stream or the NIF, and the one call it makes to `Cairn.Native.Host` is made by
  a throwaway task under a deadline — reply and deadline both arrive as messages,
  so no verdict waits on the subject.

  Three lines of evidence, because none of them sees every wedge:

    * **the probe** (`Cairn.Native.Host.probe/1`), whose deadline is a verdict:
      the Host is the only process making *synchronous* native calls, so its
      mailbox queues behind them. The deadline has to be ours because there is
      nothing cheap in the NIF to call — its four entry points are a model load,
      a decoder open/close and inference itself — and ORT/QNN offers no per-call
      deadline of its own, where HailoRT hands ex_nvr a 10 s one free.
    * **the inflight table**, written by `push_au/5`'s caller and read here
      directly. The hot path never reaches the Host, so the probe cannot see it
      wedge — and a wedged one is *silent*: the sink stops re-demanding, and
      there is no traffic, no error, no crash. A row older than the window whose
      caller is still alive is the only signal there is.
    * **the D-P5 ratio**, per stream, for the accelerator that answers — at CPU
      speed.

  ## Healthy, saturated, wedged, idle

  The NIF has no admission control, so once cameras × `sample_fps` passes what one
  session sustains the surplus is queueing time inside a `push_au/5` and "healthy
  but slow" is a real state the ratio check must not call a wedge. Throughput is
  what separates them: a saturated healthy accelerator still retires work at
  accelerator rate, and a wedged one cannot beat the CPU it fell back to.

  Both are measured on completed model passes alone — a call the motion gate
  skipped never reached the accelerator, and neither did a failed pass.

  A wedge is one operator alert per transition and never a restart: a wedged HTP
  survives `kill -9` and every restart above it (spike 0.5).
  """

  use GenServer

  require Logger

  alias Cairn.Native.Host

  @interval_ms 60_000
  # The probe's deadline, and so the whole cost of a cycle against a wedged Host.
  @probe_timeout_ms 2_000
  # Below this a window is evidence of traffic, not of latency: too few samples for
  # a p50 worth escalating on.
  @min_samples 10
  # D-P5: an accelerator not at least this much faster than the CPU baseline is not
  # executing on the accelerator.
  @min_ratio 3.0
  # How close to accelerator-rate throughput still counts as accelerator-rate, so
  # that sampling noise does not read a saturated engine as a wedged one.
  @throughput_slack 0.9
  # How many of one camera's latencies a window keeps; see `sampled/3`.
  @window 512

  @no_restart "Restarting does not clear a wedged accelerator (spike 0.5: it survives kill -9), " <>
                "so this host will not restart itself — the board needs an operator."

  defstruct [
    :host,
    :table,
    :inflight,
    :opts,
    :checked_at,
    :cycle,
    :p50_ms,
    waiting: [],
    window: %{},
    completed: 0,
    health: :unknown,
    stream_health: %{},
    stream_fps: %{}
  ]

  @type verdict :: :unknown | :not_applicable | :idle | :healthy | :saturated | :wedged

  def start_link(opts) do
    host = Keyword.get(opts, :host, Host)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :host, host), name: name(host))
  end

  @doc "Where `host`'s monitor is registered, and the table it publishes into."
  @spec name(atom()) :: atom()
  def name(host \\ Host), do: :"#{host}.health"

  @doc """
  Run a cycle now and answer with its verdict.

  The call timeout is above the probe's on purpose: this waits out a whole cycle,
  deadline included.
  """
  @spec check(atom(), timeout()) :: verdict()
  def check(name \\ name(), timeout \\ 30_000) do
    case GenServer.whereis(name) do
      # No monitor is a question nobody can answer, not a crash for the Host that
      # delegated it here.
      nil -> :unknown
      pid -> GenServer.call(pid, :check, timeout)
    end
  end

  @doc "The last cycle's verdict, readable without this process being involved."
  @spec snapshot(atom()) :: map()
  def snapshot(host \\ Host) do
    case :ets.lookup(name(host), :snapshot) do
      [{:snapshot, snapshot}] -> snapshot
      [] -> empty()
    end
  rescue
    # no monitor started yet, or one restarting: the Host still answers `status/2`
    ArgumentError -> empty()
  end

  defp empty,
    do: %{health: :unknown, stream_health: %{}, stream_fps: %{}, p50_ms: nil, inferences: 0}

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    opts = Keyword.merge(Application.get_env(:cairn, __MODULE__, []), opts)
    host = Keyword.fetch!(opts, :host)
    table = :ets.new(name(host), [:named_table, :set, :protected, read_concurrency: true])

    state = %__MODULE__{
      host: host,
      table: table,
      # Written by every `push_au/5` caller and read here: evidence about the hot
      # path that does not pass through the process the hot path can wedge.
      inflight: :"#{host}.inflight",
      checked_at: System.monotonic_time(:microsecond),
      opts: opts
    }

    schedule(state)
    {:ok, publish(state)}
  end

  @impl true
  def handle_call(:check, from, state) do
    {:noreply, state |> await(from) |> begin()}
  end

  # Untokened: a completed pass is the engine's work whichever open it belonged
  # to. Only the reports that act on stream identity are token-gated, and those
  # are the Host's (`Cairn.Native.Host.note_error/5`).
  @impl true
  def handle_info({:inference, camera_id, {:passes, passes, micros}}, state) do
    {:noreply, record(state, camera_id, passes, &sampled(&1, micros, passes))}
  end

  # Traffic, never work retired (`window/2`): a stream doing nothing but erroring
  # must reach the cross-stream verdict rather than read as silence.
  def handle_info({:inference, camera_id, :failed}, state) do
    {:noreply, record(state, camera_id, 0, &%{&1 | errors: &1.errors + 1})}
  end

  def handle_info(:poll, state) do
    schedule(state)
    {:noreply, begin(state)}
  end

  def handle_info({ref, reply}, %{cycle: %{task: %{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, {:ok, reply})}
  end

  # The probe task died without answering: no Host to judge, which is a
  # supervisor's problem and not a wedge.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{cycle: %{task: %{ref: ref}}} = state) do
    {:noreply, finish(state, :no_subject)}
  end

  def handle_info({:deadline, ref}, %{cycle: %{task: %{ref: ref} = task}} = state) do
    # Killed rather than left to land: its reply would otherwise arrive against a
    # later cycle, and the call it is inside is the thing being reported.
    Task.shutdown(task, :brutal_kill)
    {:noreply, finish(state, :timeout)}
  end

  # A reply or deadline for a cycle already decided, and the probe task's own
  # stray exits.
  def handle_info(_message, state), do: {:noreply, state}

  # -- the cycle --------------------------------------------------------------

  defp schedule(state) do
    Process.send_after(self(), :poll, opt(state, :interval_ms, @interval_ms))
  end

  defp await(state, from), do: %{state | waiting: [from | state.waiting]}

  # One cycle at a time: a `check/2` landing inside the running one is answered by
  # it rather than starting a second probe.
  defp begin(%{cycle: nil} = state) do
    host = state.host
    task = Task.Supervisor.async_nolink(Cairn.TaskSupervisor, fn -> Host.probe(host) end)

    timer =
      Process.send_after(
        self(),
        {:deadline, task.ref},
        opt(state, :probe_timeout_ms, @probe_timeout_ms)
      )

    %{state | cycle: %{task: task, timer: timer}}
  end

  defp begin(state), do: state

  defp finish(state, probe) do
    Process.cancel_timer(state.cycle.timer)
    now = System.monotonic_time(:microsecond)
    window = window(state, now)
    per_stream = Map.new(state.window, fn {id, entry} -> {id, classify(state, entry)} end)
    verdict = verdict(probe, state, window, per_stream)

    state
    |> escalate(verdict, probe, per_stream)
    |> Map.merge(%{
      cycle: nil,
      checked_at: now,
      window: %{},
      health: verdict,
      stream_health: per_stream,
      stream_fps: stream_fps(state.window, window.elapsed_ms),
      p50_ms: window_p50(state)
    })
    |> publish()
    |> answer(verdict)
  end

  # `traffic` (passes and failures alike) is whether anything is happening at all;
  # `retired` (completed passes) is whether the accelerator is executing — an error
  # proves the first and never the second.
  defp window(state, now) do
    {retired, errors} =
      Enum.reduce(state.window, {0, 0}, fn {_id, e}, {retired, errors} ->
        {retired + e.count, errors + e.errors}
      end)

    %{
      retired: retired,
      traffic: retired + errors,
      # not a window count: a caller blocked inside the NIF is still registered in
      # every window it is stuck in
      stalled: length(stalled(inflight(state), state.checked_at)),
      elapsed_ms: max(div(now - state.checked_at, 1000), 1)
    }
  end

  defp answer(state, verdict) do
    Enum.each(state.waiting, &GenServer.reply(&1, verdict))
    %{state | waiting: []}
  end

  defp publish(state) do
    :ets.insert(
      state.table,
      {:snapshot,
       %{
         health: state.health,
         stream_health: state.stream_health,
         stream_fps: state.stream_fps,
         p50_ms: state.p50_ms,
         # model passes, not `push_au/5` calls: at 5 fps sampled off a 20 fps
         # camera the two differ by the frame rate
         inferences: state.completed
       }}
    )

    state
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
    samples = if entry.count >= @window, do: entry.samples, else: [sample | entry.samples]
    %{entry | samples: samples, count: entry.count + passes}
  end

  # -- the verdict ------------------------------------------------------------

  # The deadline is a verdict on its own: the Host is inside a native call that has
  # not returned, and no window statistic is needed to say so — nor available, since
  # a Host that cannot answer cannot be asked what it thinks either.
  defp verdict(:timeout, _state, _window, _streams), do: :wedged
  defp verdict(:no_subject, _state, _window, _streams), do: :unknown

  defp verdict({:ok, %{engine: :ready}}, state, window, streams),
    do: judge(state, window, streams)

  defp verdict({:ok, _status}, _state, _window, _streams), do: :unknown

  #   * no pass came back -> :idle, unless a call has been in flight since before
  #     this window, whose own age is evidence of a live caller blocked inside the
  #     NIF (`stalled/2`) -> :wedged instead.
  #   * a stream with traffic nobody can judge yet -> :unknown, because the
  #     expensive direction is the false page.
  #   * every stream with traffic failing or slow -> the accelerator, unless retired
  #     throughput is still at accelerator rate -> :saturated instead.
  defp judge(_state, %{traffic: 0, stalled: stalled}, _streams) when stalled > 0, do: :wedged
  defp judge(_state, %{traffic: 0}, _streams), do: :idle

  defp judge(state, window, streams) do
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
      entry.count < opt(state, :min_samples, @min_samples) -> :unknown
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
    observed >= min_ratio(state) * cpu_rate * @throughput_slack
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
  rescue
    # The table is the Host's and dies with it. A window that lands in that restart
    # has no outstanding calls to read, which is also the truth.
    ArgumentError -> []
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

  defp escalate(%{health: :wedged} = state, :wedged, _probe, _streams), do: state

  defp escalate(state, :wedged, :timeout, _streams) do
    Logger.error(
      "cairn-native: NPU health check FAILED — #{inspect(state.host)} did not answer a " <>
        "#{opt(state, :probe_timeout_ms, @probe_timeout_ms)} ms probe, so it is inside a native " <>
        "call that has not returned. " <> @no_restart
    )

    state
  end

  defp escalate(state, :wedged, _probe, streams) do
    Logger.error(
      "cairn-native: NPU health check FAILED — every stream with traffic is failing, or is " <>
        "under the #{min_ratio(state)}× D-P5 floor against a #{baseline(state)} ms CPU " <>
        "baseline with no throughput to explain it as saturation (#{inspect(streams)}). " <>
        @no_restart
    )

    state
  end

  defp escalate(%{health: :wedged} = state, verdict, _probe, _streams) do
    Logger.warning("cairn-native: NPU health recovered to #{verdict}")
    state
  end

  defp escalate(state, _verdict, _probe, _streams), do: state

  # Completed model passes per second, per camera — the `fps` a plugin reports for
  # itself, measured over the window that has just closed rather than since boot.
  defp stream_fps(window, elapsed_ms) do
    Map.new(window, fn {id, entry} -> {id, Float.round(entry.count * 1000 / elapsed_ms, 2)} end)
  end

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

  defp baseline(state), do: opt(state, :cpu_baseline_ms, nil)
  defp min_ratio(state), do: opt(state, :min_ratio, @min_ratio)

  defp opt(state, key, default), do: Keyword.get(state.opts, key, default)
end
