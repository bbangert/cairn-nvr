defmodule Cairn.PresenceAggregator do
  @moduledoc """
  A tier-1 camera's per-class present/cleared state machine — what that tier
  runs *instead of* a tracker.

  Fed by `Cairn.Pipeline.PresenceSink` with one call per detected frame —
  a multi-frame `Detections` buffer is several calls sharing one clock
  read, which is why a sighting is counted per call, not per instant
  (`sighted/5`): the labels seen (already floored by the camera's
  effective `min_score`) and the frame's monotonic instant. Emits
  `Cairn.PresenceEvent`s on the transitions and nothing between them —
  presence is edge-triggered, so there is no update stream to throttle.

  Every threshold is milliseconds, never a frame count: tier-1 delivery
  floats with fleet load by design (the capacity paradigm — ~7.5/s on a
  quiet fleet down to ~1.9/s at the 40-camera floor), and a frame-counted
  rule would mean 4x different confirm latencies depending on how many
  cameras a node runs.

  Clearing is **gate-aware**: the motion gate ahead of inference closes on a
  still scene, and a closed gate means no batches — silence. Silence is not
  absence: whatever was present when the scene went still is, by the gate's
  own logic, still there (leaving would have moved, and motion reopens the
  gate). So the clear window advances only on batches that *arrive* without
  the label — frames flowed, the model ran, the class was gone — and pure
  silence clears nothing until the long `@silence_timeout_ms` backstop, which
  exists for streams that die rather than scenes that sleep.
  """

  use GenServer, restart: :transient

  require Logger

  alias Cairn.PresenceEvent

  # Two sightings inside this window confirm presence. Two, not one — a
  # single-frame phantom must not open an event — and the window is wide
  # enough that the 40-camera floor rate (~1.9/s, 530 ms gaps) confirms on
  # its second consecutive sighting.
  @confirm_window_ms 2_000
  # Evidence-of-absence span: batches kept arriving without the label for
  # this long. Spans several sampling gaps at the floor rate, so one missed
  # detection cannot clear a real object.
  @clear_after_ms 5_000
  # The backstop for a dead stream (camera offline, pipeline down): the one
  # clearing that wall-clock silence may perform. Long on purpose — see the
  # gate-aware rule in the moduledoc.
  @silence_timeout_ms 600_000
  @silence_check_ms 60_000

  @doc false
  def start_link(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)
    GenServer.start_link(__MODULE__, camera_id, name: Cairn.Registry.via(camera_id, :presence))
  end

  @doc """
  One batch's evidence: the best score per label that survived the floor,
  at the batch's monotonic instant. An empty map is still evidence — frames
  flowed and nothing qualified — and advances clearing.
  """
  @spec observed(String.t(), integer(), %{String.t() => float()}) :: :ok
  def observed(camera_id, at_ms, seen) when is_map(seen) do
    case ensure(camera_id) do
      {:ok, pid} ->
        GenServer.cast(pid, {:observed, at_ms, seen})

      {:error, reason} ->
        Logger.debug("camera #{camera_id}: no presence aggregator (#{inspect(reason)})")
        :ok
    end
  end

  @doc """
  Detection was switched off: clear everything now, events and all.

  The disabled state is an operator's statement that nothing is watching,
  which is a different fact from a closed gate — presence held through it
  would be a claim no frames back.
  """
  @spec detection_disabled(String.t()) :: :ok
  def detection_disabled(camera_id) do
    # whereis, not ensure: with nothing running there is nothing to clear,
    # and starting an empty aggregator just to tell it so would leave one
    # running on every disabled camera.
    case Cairn.Registry.whereis(camera_id, :presence) do
      nil -> :ok
      pid -> GenServer.cast(pid, :detection_disabled)
    end
  end

  @spec ensure(String.t()) :: {:ok, pid()} | {:error, term()}
  defp ensure(camera_id) do
    case Cairn.Registry.whereis(camera_id, :presence) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> start_aggregator(camera_id)
    end
  end

  defp start_aggregator(camera_id) do
    case DynamicSupervisor.start_child(
           Cairn.PresenceSupervisor,
           {__MODULE__, camera_id: camera_id}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  def init(camera_id) do
    Process.send_after(self(), :silence_check, @silence_check_ms)

    {:ok,
     %{
       camera_id: camera_id,
       # label => %{phase: :pending | :present, first_seen_ms, last_seen_ms,
       # best_score, first_seen_at} — `first_seen_at` is the wall instant the
       # outward-facing events carry; every bound is measured on the
       # monotonic *_ms fields.
       labels: %{},
       last_batch_ms: nil
     }}
  end

  @impl true
  def handle_cast({:observed, at_ms, seen}, state) do
    labels =
      state.labels
      |> sightings(seen, at_ms, state.camera_id)
      |> absences(seen, at_ms, state.camera_id)

    {:noreply, %{state | labels: labels, last_batch_ms: at_ms}}
  end

  def handle_cast(:detection_disabled, state) do
    {:noreply, clear_all(state)}
  end

  # Wall-clock silence: only the dead-stream backstop, per the moduledoc.
  # Monotonic here too — `last_batch_ms` is the sink's monotonic stamp.
  @impl true
  def handle_info(:silence_check, state) do
    Process.send_after(self(), :silence_check, @silence_check_ms)
    now = System.monotonic_time(:millisecond)

    if state.last_batch_ms != nil and now - state.last_batch_ms >= @silence_timeout_ms do
      {:noreply, clear_all(state)}
    else
      {:noreply, state}
    end
  end

  defp sightings(labels, seen, at_ms, camera_id) do
    Enum.reduce(seen, labels, fn {label, score}, labels ->
      Map.put(labels, label, sighted(Map.get(labels, label), label, score, at_ms, camera_id))
    end)
  end

  defp sighted(nil, _label, score, at_ms, _camera_id) do
    %{
      phase: :pending,
      first_seen_ms: at_ms,
      last_seen_ms: at_ms,
      best_score: score,
      first_seen_at: DateTime.utc_now()
    }
  end

  # The second sighting inside the window confirms; one outside it means the
  # first was a lone flicker — the candidacy restarts rather than confirming
  # off two sightings a minute apart. A sighting is a CALL, not an instant:
  # two frames of one multi-frame buffer reach here as two calls sharing the
  # sink's per-buffer clock read, and they are two model passes on two source
  # frames — exactly the two consecutive detections the confirm asks for —
  # so an equal `at_ms` must not be collapsed into one.
  defp sighted(%{phase: :pending} = entry, label, score, at_ms, camera_id) do
    if at_ms - entry.first_seen_ms <= @confirm_window_ms do
      entry = %{
        entry
        | phase: :present,
          best_score: max(entry.best_score, score),
          last_seen_ms: at_ms
      }

      broadcast(:presence_started, camera_id, label, entry)
      entry
    else
      sighted(nil, label, score, at_ms, camera_id)
    end
  end

  defp sighted(%{phase: :present} = entry, _label, score, at_ms, _camera_id) do
    %{entry | best_score: max(entry.best_score, score), last_seen_ms: at_ms}
  end

  # Runs on the post-`sightings/4` map, so anything this batch carried was
  # just stamped `last_seen_ms: at_ms` and the age check alone keeps it. A
  # stale `:pending` vanishes without an event — nothing was ever announced.
  defp absences(labels, _seen, at_ms, camera_id) do
    Enum.reduce(labels, %{}, fn {label, entry}, kept ->
      cond do
        at_ms - entry.last_seen_ms < @clear_after_ms ->
          Map.put(kept, label, entry)

        entry.phase == :present ->
          broadcast(:presence_cleared, camera_id, label, entry)
          kept

        true ->
          kept
      end
    end)
  end

  # `last_batch_ms` resets too: everything is cleared, so there is no batch
  # history left to age — without this the silence backstop would re-run an
  # empty clear every check until the next batch arrives.
  defp clear_all(state) do
    for {label, %{phase: :present} = entry} <- state.labels do
      broadcast(:presence_cleared, state.camera_id, label, entry)
    end

    %{state | labels: %{}, last_batch_ms: nil}
  end

  defp broadcast(kind, camera_id, label, entry) do
    PresenceEvent.broadcast(kind, %PresenceEvent{
      camera_id: camera_id,
      label: label,
      score: entry.best_score,
      first_seen_at: entry.first_seen_at,
      at: DateTime.utc_now()
    })
  end
end
