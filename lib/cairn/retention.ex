defmodule Cairn.Retention do
  @moduledoc """
  Two periodic sweeps over the stored history:

    * **Retention prune** (hourly): deletes clip + snapshot + track-path
      sidecar + row (`Cairn.Events.delete/1`) once an event outlives its
      effective retention — the max of the per-label overrides for labels
      present in the event (camera-level overrides win over globals, see
      `Cairn.Config.retention_days/3`). The same pass then expires track rows
      on their own, much longer clock (`retention.tracks_days`), which has no
      per-camera or per-label form.
    * **Emergency disk cleanup** (every 60s): when free space under
      `data_dir` drops below `free_space_min_mb`, deletes oldest events
      regardless of retention until above the threshold, and broadcasts a
      persistent alert on `"system:alerts"` (`{:disk_alert, %{active:
      boolean, free_mb: n, threshold_mb: n}}`).

  Track *rows* are never touched by the emergency path, and outlive the clips
  either way. A clip's bbox sidecar is not a row: it is part of the event's
  media and goes whenever the event does, by either sweep.
  """

  use GenServer

  require Logger

  alias Cairn.{Config, Events, Tracks}

  @topic "system:alerts"
  @prune_interval_ms :timer.hours(1)
  @emergency_interval_ms :timer.seconds(60)
  # deleting one event at a time keeps us from overshooting the threshold
  @emergency_batch 1

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Cairn.PubSub, @topic)

  @doc "Current disk alert state (for LiveView mounts)."
  @spec alert(GenServer.server()) :: %{active: boolean()}
  def alert(server \\ __MODULE__), do: GenServer.call(server, :alert)

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      opts: opts,
      alert: %{active: false},
      config_fun: Keyword.get(opts, :config_fun, &Cairn.Config.Server.get/0),
      free_space_fun: Keyword.get(opts, :free_space_fun, &free_space_bytes/1)
    }

    unless Keyword.get(opts, :manual, false) do
      schedule(:prune, Keyword.get(opts, :prune_interval_ms, @prune_interval_ms))
      schedule(:emergency, Keyword.get(opts, :emergency_interval_ms, @emergency_interval_ms))
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:alert, _from, state), do: {:reply, state.alert, state}

  @impl true
  def handle_info(:prune, state) do
    unless state.opts[:manual] do
      schedule(:prune, Keyword.get(state.opts, :prune_interval_ms, @prune_interval_ms))
    end

    run_prune(state.config_fun.())
    {:noreply, state}
  end

  def handle_info(:emergency, state) do
    unless state.opts[:manual] do
      schedule(
        :emergency,
        Keyword.get(state.opts, :emergency_interval_ms, @emergency_interval_ms)
      )
    end

    {:noreply, run_emergency(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- prune ------------------------------------------------------------------

  @doc false
  def run_prune(%Config{} = config) do
    now = DateTime.utc_now()

    deleted =
      now
      |> DateTime.add(-min_retention_days(config) * 86_400, :second)
      |> Events.finished_started_before()
      |> Enum.count(fn row ->
        days = effective_retention_days(config, row)
        expired? = DateTime.compare(row.started_at, DateTime.add(now, -days * 86_400)) == :lt

        if expired? do
          delete_event(row)
          true
        else
          false
        end
      end)

    if deleted > 0, do: Logger.info("retention: pruned #{deleted} events")

    prune_tracks(config, now)

    # the return is the event count alone — the track sweep reports through the
    # log, since nothing calls this for a total
    deleted
  end

  # Track rows run on their own clock, off the same `now` as the event sweep so
  # one pass has one notion of the present. Live tracks are never eligible
  # however old they are — `delete_ended_before/1` compares `ended_at`, which is
  # NULL until a track finishes. Moments go with their track by cascade.
  defp prune_tracks(config, now) do
    count =
      now
      |> DateTime.add(-config.retention_tracks_days * 86_400, :second)
      |> Tracks.delete_ended_before()

    if count > 0, do: Logger.info("retention: pruned #{count} tracks")
    count
  end

  # the earliest any event could expire — used to narrow the candidate query
  defp min_retention_days(config) do
    camera_days =
      for cam <- config.cameras,
          days <- [cam.retention_days | Map.values(cam.retention_per_label)],
          is_integer(days),
          do: days

    Enum.min([config.retention_days | Map.values(config.retention_per_label)] ++ camera_days)
  end

  defp effective_retention_days(config, row) do
    camera =
      Enum.find(config.cameras, &(&1.id == row.camera_id)) || %Config.Camera{id: row.camera_id}

    labels = row.labels |> Map.get("max_scores", %{}) |> Map.keys()

    case labels do
      [] -> camera.retention_days || config.retention_days
      labels -> labels |> Enum.map(&Config.retention_days(config, camera, &1)) |> Enum.max()
    end
  end

  # -- emergency --------------------------------------------------------------

  # Clips only, deliberately: this path deletes events — clip, snapshot and
  # bbox sidecar with them — and never track rows. A track row is a few hundred
  # bytes against megabytes for a clip, so pruning
  # tracks would reclaim nothing worth having while destroying the audit record
  # — "what did the system see and not record?" — that is the reason to keep
  # them past the clips at all. If deleting every event still leaves the disk
  # full, the track index is not what filled it.
  defp run_emergency(state) do
    config = state.config_fun.()
    threshold = config.free_space_min_mb * 1024 * 1024

    case state.free_space_fun.(config.data_dir) do
      {:ok, free} when free < threshold ->
        deleted = emergency_delete(state, threshold, 0)

        Logger.warning(
          "emergency cleanup: free space #{div(free, 1024 * 1024)}MB below " <>
            "#{config.free_space_min_mb}MB, deleted #{deleted} oldest events"
        )

        set_alert(state, true, config)

      {:ok, _free} ->
        set_alert(state, false, config)

      {:error, reason} ->
        Logger.warning("emergency cleanup: cannot stat free space: #{inspect(reason)}")
        state
    end
  end

  defp emergency_delete(state, threshold, deleted) do
    config = state.config_fun.()

    case Events.oldest_for_cleanup(@emergency_batch) do
      [] ->
        deleted

      rows ->
        Enum.each(rows, &delete_event/1)

        case state.free_space_fun.(config.data_dir) do
          {:ok, free} when free < threshold ->
            emergency_delete(state, threshold, deleted + length(rows))

          _ ->
            deleted + length(rows)
        end
    end
  end

  defp set_alert(state, active, config) do
    if state.alert.active != active do
      free_mb =
        case state.free_space_fun.(config.data_dir) do
          {:ok, free} -> div(free, 1024 * 1024)
          _ -> nil
        end

      alert = %{active: active, free_mb: free_mb, threshold_mb: config.free_space_min_mb}
      Phoenix.PubSub.broadcast(Cairn.PubSub, @topic, {:disk_alert, alert})
      %{state | alert: alert}
    else
      state
    end
  end

  # -- shared -----------------------------------------------------------------

  defp delete_event(row), do: Events.delete(row)

  defp free_space_bytes(data_dir) do
    case System.cmd("df", ["-Pk", data_dir], stderr_to_stdout: true) do
      {out, 0} ->
        case out |> String.split("\n", trim: true) |> Enum.at(1, "") |> String.split() do
          [_fs, _blocks, _used, avail | _] -> {:ok, String.to_integer(avail) * 1024}
          _ -> {:error, :unparseable}
        end

      {_out, status} ->
        {:error, {:df_failed, status}}
    end
  rescue
    e -> {:error, e}
  end

  defp schedule(msg, interval), do: Process.send_after(self(), msg, interval)
end
