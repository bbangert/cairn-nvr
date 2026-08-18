defmodule Cairn.SoakMonitor do
  @moduledoc """
  The steady-state soak's evidence trail: one JSON sample a minute into
  `{data_dir}/soak/samples.jsonl` and a rolling `report.md` beside it.

  In-process and always on rather than a harness Ben must start, because the
  soak's subject is the real node under real cameras (tier1-container phase
  5) and the questions are app-level: BEAM memory slope, Host restarts, the
  every-started-gets-a-cleared presence invariant, event counts, alerts.
  Container restarts fall out for free — each boot appends a `boot` record,
  so the sample file spans them while counters restart with the node.

  Observation only: subscriptions and reads, no calls into the engine or the
  NIFs — a monitor that could wedge on its subject would vanish exactly when
  it matters. Thermals and governor come from `/sys` (visible in-container);
  a host that exposes neither samples as `nil` rather than failing, but the
  governor is recorded on purpose: schedutil quietly flattens QNN to ~2.3×
  and a soak that did not log it would claim numbers nobody can interpret.
  """

  use GenServer

  require Logger

  alias Cairn.CameraStatus
  alias Cairn.Config.Server
  alias Cairn.Event
  alias Cairn.Native.Host

  @interval_ms 60_000
  # One rotation, not a ring: at ~350 bytes/sample this is weeks of history,
  # and the soak's disk budget is bounded at two files forever.
  @max_bytes 10_485_760

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The directory the current config puts samples in — the report names it."
  @spec dir(Path.t()) :: Path.t()
  def dir(data_dir), do: Path.join(data_dir, "soak")

  @impl true
  def init(opts) do
    config = Application.get_env(:cairn, __MODULE__, [])

    if Keyword.get(config, :enabled, true) do
      Phoenix.PubSub.subscribe(Cairn.PubSub, Event.topic())
      CameraStatus.subscribe()
      Phoenix.PubSub.subscribe(Cairn.PubSub, "system:alerts")

      interval = Keyword.get(opts, :interval_ms, Keyword.get(config, :interval_ms, @interval_ms))

      state = %{
        interval_ms: interval,
        dir: Keyword.get(opts, :dir) || dir(Server.get().data_dir),
        max_bytes: Keyword.get(opts, :max_bytes, @max_bytes),
        booted_at: DateTime.utc_now(),
        counts: %{},
        host_pid: Process.whereis(Host),
        host_restarts: 0,
        first_sample: nil,
        last_sample: nil
      }

      append(state, %{boot: true, at: state.booted_at})
      Process.send_after(self(), :sample, interval)
      {:ok, state}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:sample, state) do
    state =
      state
      |> detect_host_restart(Process.whereis(Host))
      |> record_sample()

    Process.send_after(self(), :sample, state.interval_ms)
    {:noreply, state}
  end

  # Every broadcast the three topics carry is a tagged tuple; the tag alone is
  # the count that matters here (`presence_started` vs `presence_cleared`,
  # alert kinds, track/event lifecycle).
  def handle_info({kind, _payload}, state) when is_atom(kind) do
    {:noreply, %{state | counts: Map.update(state.counts, kind, 1, &(&1 + 1))}}
  end

  def handle_info({kind, _id, _payload}, state) when is_atom(kind) do
    {:noreply, %{state | counts: Map.update(state.counts, kind, 1, &(&1 + 1))}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Public and pid-injected for the test: restarting the real Host inside the
  # shared test tree would disturb every other suite.
  @doc false
  @spec detect_host_restart(map(), pid() | nil) :: map()
  def detect_host_restart(state, current_pid) do
    case current_pid do
      pid when pid == state.host_pid -> state
      pid when is_nil(state.host_pid) -> %{state | host_pid: pid}
      pid -> %{state | host_pid: pid, host_restarts: state.host_restarts + 1}
    end
  end

  defp record_sample(state) do
    sample = sample(state)
    append(state, sample)
    state = %{state | first_sample: state.first_sample || sample, last_sample: sample}
    write_report(state)
    state
  end

  defp sample(state) do
    memory = :erlang.memory()

    %{
      at: DateTime.utc_now(),
      memory_total: memory[:total],
      memory_processes: memory[:processes],
      memory_binary: memory[:binary],
      memory_ets: memory[:ets],
      process_count: length(Process.list()),
      # Both NIFs, separately: the decode and inference halves load
      # independently, and a report that aggregated them would say "loaded"
      # while the inference half silently wasn't.
      native_available: Cairn.Native.available?(),
      ort_available: CairnOrt.available?(),
      host_restarts: state.host_restarts,
      presence_ledger: ets_size(Cairn.PresenceLedger),
      counts: state.counts,
      governor: read_trimmed("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"),
      max_temp_mc: max_thermal()
    }
  end

  defp ets_size(table) do
    case :ets.info(table, :size) do
      :undefined -> nil
      size -> size
    end
  end

  defp read_trimmed(path) do
    case File.read(path) do
      {:ok, content} -> String.trim(content)
      {:error, _} -> nil
    end
  end

  defp max_thermal do
    "/sys/class/thermal/thermal_zone*/temp"
    |> Path.wildcard()
    |> Enum.flat_map(&parse_millidegrees/1)
    |> Enum.max(fn -> nil end)
  end

  defp parse_millidegrees(zone) do
    case Integer.parse(read_trimmed(zone) || "") do
      {millidegrees, ""} -> [millidegrees]
      _unreadable -> []
    end
  end

  defp append(state, record) do
    path = Path.join(state.dir, "samples.jsonl")
    File.mkdir_p!(state.dir)
    rotate(path, state.max_bytes)
    File.write!(path, Jason.encode!(record) <> "\n", [:append])
  rescue
    # A full disk must degrade the evidence trail, never the node under soak.
    error -> Logger.warning("soak-monitor: sample not written: #{Exception.message(error)}")
  end

  defp rotate(path, max_bytes) do
    case File.stat(path) do
      {:ok, %{size: size}} when size >= max_bytes -> File.rename(path, path <> ".1")
      _small_or_absent -> :ok
    end
  end

  defp write_report(%{last_sample: sample} = state) do
    started = Map.get(sample.counts, :presence_started, 0)
    cleared = Map.get(sample.counts, :presence_cleared, 0)

    report = """
    # Soak report (rolling — regenerated each sample)

    - node booted: #{state.booted_at} (each boot appends a `boot` record to samples.jsonl;
      count those for container restarts)
    - last sample: #{sample.at}
    - BEAM memory: #{mb(sample.memory_total)} MB total (processes #{mb(sample.memory_processes)},
      binary #{mb(sample.memory_binary)}, ets #{mb(sample.memory_ets)});
      slope #{slope_mb_per_day(state)} MB/day since boot
    - processes: #{sample.process_count}
    - NIFs loaded: decode #{sample.native_available}, inference #{sample.ort_available};
      Host restarts since boot: #{sample.host_restarts}
    - presence: started #{started} / cleared #{cleared} since boot; ledger now
      #{inspect(sample.presence_ledger)} open (invariant: drains to 0 when scenes are empty)
    - event/track/alert counts since boot: #{inspect(sample.counts)}
    - governor: #{inspect(sample.governor)} (schedutil flattens QNN to ~2.3× — pin
      `performance` for any cell that claims numbers)
    - max thermal zone: #{inspect(sample.max_temp_mc)} m°C
    """

    case File.write(Path.join(state.dir, "report.md"), report) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("soak-monitor: report not written: #{inspect(reason)}")
    end
  end

  defp mb(nil), do: "?"
  defp mb(bytes), do: div(bytes, 1_048_576)

  defp slope_mb_per_day(%{first_sample: first, last_sample: last})
       when first != nil and last != nil and first != last do
    seconds = DateTime.diff(last.at, first.at)

    if seconds > 0 do
      Float.round((last.memory_total - first.memory_total) / 1_048_576 * 86_400 / seconds, 1)
    else
      0.0
    end
  end

  defp slope_mb_per_day(_state), do: 0.0
end
