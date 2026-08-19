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
  gate). So the clear window is a span of absence EVIDENCE — opened by the
  first batch that arrives without the label and closed by another at least
  `@clear_after_ms` later; frames flowed, the model ran, the class was gone,
  twice. Pure silence clears nothing until the long `@silence_timeout_ms`
  backstop, which exists for streams that die rather than scenes that
  sleep — and silence *between* the two absent observations does count,
  since the first already testified to the absence the silence preserved.
  (`heartbeat/2` is how an all-skip buffer — the native gate's spelling of
  a sleeping scene — tells the backstop the stream is not dead.)

  The invariant every path serves: **every `presence_started` is followed
  by exactly one `presence_cleared`** — through evidence, disable, retire,
  the backstop, and a crash. The crash leg is `Cairn.PresenceLedger`'s: a
  restarted aggregator clears its predecessor's announced labels in
  `init/1` before doing anything else, then re-confirms from live batches.
  """

  use GenServer, restart: :transient

  require Logger

  alias Cairn.{PresenceEvent, PresenceRecorder}

  # Two sightings inside this window confirm presence. Two, not one — a
  # single-frame phantom must not open an event — and the window is wide
  # enough that the 40-camera floor rate (~1.9/s, 530 ms gaps) confirms on
  # its second consecutive sighting.
  @confirm_window_ms 2_000
  # Evidence-of-absence span: from the FIRST batch without the label to an
  # absent batch at least this much later — never from `last_seen_ms`, which
  # would count any gate-closed silence toward the window and let a single
  # absent batch clear a still-present object the moment the gate reopens.
  # Clearing therefore always takes two absent observations, and spans
  # several sampling gaps at the floor rate, so one missed detection cannot
  # clear a real object.
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
  The stream is alive but nothing was model-inferred — a native motion
  gate skipping passes on a still scene. Refreshes the silence backstop's
  clock and nothing else: a gated stream is not a dead one, and without
  this the backstop would clear a standing presence after 600 s of
  healthy skip frames. `whereis`, not `ensure` — liveness for no state is
  nothing.
  """
  @spec heartbeat(String.t(), integer()) :: :ok
  def heartbeat(camera_id, at_ms) do
    case Cairn.Registry.whereis(camera_id, :presence) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:heartbeat, at_ms})
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

  @doc """
  The camera is going away (removed, or restarting under a changed config —
  a tier flip included): clear everything, then stop.

  `Cairn.CameraSupervisor.stop_camera/1` is the one caller, which is what
  scopes the lifecycle: an ordinary crash/watchdog rebuild never passes
  through there, so presence survives reconnects — and a camera that leaves
  the config or changes shape takes its aggregator with it instead of
  leaving stale presence standing until the silence backstop.
  """
  @spec retire(String.t()) :: :ok
  def retire(camera_id) do
    # The lane's sibling goes with it. It outlives this call when an event is
    # open — the cleareds `clear_all/1` is about to emit are what close that
    # one — see `Cairn.PresenceRecorder.retire/1`.
    PresenceRecorder.retire(camera_id)

    case Cairn.Registry.whereis(camera_id, :presence) do
      nil -> :ok
      pid -> GenServer.cast(pid, :retire)
    end
  end

  @spec ensure(String.t()) :: {:ok, pid()} | {:error, term()}
  defp ensure(camera_id) do
    case Cairn.Registry.whereis(camera_id, :presence) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> start_aggregator(camera_id)
    end
  end

  # Started with the aggregator rather than on demand from the sink's frame
  # path: what triggers a recording is a transition cast, and
  # `PresenceRecorder.presence/3` drops one that finds no recorder.
  defp start_aggregator(camera_id) do
    PresenceRecorder.ensure(camera_id)

    case DynamicSupervisor.start_child(
           Cairn.PresenceSupervisor.Pool,
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
    # A predecessor's unanswered announcements clear FIRST: presence is
    # edge-only, so a crash that lost the labels map would otherwise leave
    # every client that tracked the edges stuck at "present" with no
    # cleared ever coming (the every-started-gets-a-cleared invariant —
    # `Cairn.PresenceLedger`). A fresh camera has no leftovers and this is
    # a no-op.
    for {label, first_seen_at, score} <- Cairn.PresenceLedger.leftovers(camera_id) do
      cleared = %PresenceEvent{
        camera_id: camera_id,
        label: label,
        score: score,
        first_seen_at: first_seen_at,
        at: DateTime.utc_now()
      }

      # Emit before delete, here and in `broadcast/4`: a crash between the
      # two leaves the row for the NEXT restart, whose clear is then a
      # duplicate — the ledger's stated bargain is at-least-once ("at worst
      # spurious, never missing"), and deleting first would invert it into
      # a cleared that can vanish.
      PresenceEvent.broadcast(:presence_cleared, cleared)
      # The event lane hears every clear this process owes, this one included:
      # a recorder holding an event open on a label whose aggregator died
      # would otherwise wait out `max_event` for a scene that already ended.
      PresenceRecorder.presence(camera_id, :presence_cleared, cleared)

      Cairn.PresenceLedger.cleared(camera_id, label)
    end

    # The out-of-band half of `detection_disabled/1`: the sink's own call
    # only fires when a buffer arrives, and a closed motion gate delivers
    # none — an operator disabling detection behind a still scene would
    # otherwise wait on motion or the silence backstop for the clear the
    # API promises is immediate.
    Cairn.CameraControl.subscribe()
    Process.send_after(self(), :silence_check, @silence_check_ms)

    {:ok,
     %{
       camera_id: camera_id,
       # label => %{phase: :pending | :present, first_seen_ms, last_seen_ms,
       # absent_since_ms, best_score, first_seen_at} — `first_seen_at` is the
       # wall instant the outward-facing events carry; every bound is
       # measured on the monotonic *_ms fields.
       labels: %{},
       last_batch_ms: nil
     }}
  end

  # The disable re-check is at CONSUME time on purpose: the sink's own
  # control read happens a message earlier in another process, so a batch
  # already in flight when the disable broadcast cleared this state would
  # otherwise re-mint presence that nothing then clears until the backstop.
  # Reading the ETS overlay here sees whatever the broadcast announced.
  @impl true
  def handle_cast({:observed, at_ms, seen}, state) do
    case Cairn.CameraControl.get(state.camera_id) do
      %{detection_enabled: false} ->
        {:noreply, state}

      _enabled ->
        labels =
          state.labels
          |> sightings(seen, at_ms, state.camera_id)
          |> absences(seen, at_ms, state.camera_id)

        {:noreply, %{state | labels: labels, last_batch_ms: at_ms}}
    end
  end

  def handle_cast({:heartbeat, at_ms}, state) do
    {:noreply, %{state | last_batch_ms: at_ms}}
  end

  def handle_cast(:detection_disabled, state) do
    {:noreply, clear_all(state)}
  end

  # `:transient` restarts abnormal exits only, so this normal stop is final;
  # the registry unregisters on DOWN and a next batch starts a fresh one.
  def handle_cast(:retire, state) do
    {:stop, :normal, clear_all(state)}
  end

  # The control topic carries every camera; only this one's disable acts.
  @impl true
  def handle_info({:camera_control, camera_id, %{detection_enabled: false}}, state)
      when camera_id == state.camera_id do
    {:noreply, clear_all(state)}
  end

  def handle_info({:camera_control, _camera_id, _control}, state), do: {:noreply, state}

  # Wall-clock silence: only the dead-stream backstop, per the moduledoc.
  # Monotonic here too — `last_batch_ms` is the sink's monotonic stamp.
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
      absent_since_ms: nil,
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
          last_seen_ms: at_ms,
          absent_since_ms: nil
      }

      broadcast(:presence_started, camera_id, label, entry)
      entry
    else
      sighted(nil, label, score, at_ms, camera_id)
    end
  end

  defp sighted(%{phase: :present} = entry, label, score, at_ms, camera_id) do
    # The ledger row follows an improving best, so a crash-recovery clear
    # carries what the cleared contract promises — the best over the whole
    # stay, not the best as of the confirmation.
    if score > entry.best_score do
      Cairn.PresenceLedger.announced(camera_id, label, entry.first_seen_at, score)
    end

    %{
      entry
      | best_score: max(entry.best_score, score),
        last_seen_ms: at_ms,
        absent_since_ms: nil
    }
  end

  # Only the labels this batch did NOT carry are absence evidence — the
  # `seen` check is load-bearing, because a label sighted this very batch
  # has `absent_since_ms: nil` too and the second clause would open a span
  # on its own sighting. The span is measured absent-batch to absent-batch
  # (see `@clear_after_ms`) — silence between the two counts, because the
  # first already testified to the absence the silence then preserved. A
  # stale `:pending` vanishes by the same rule, without an event — nothing
  # was ever announced.
  defp absences(labels, seen, at_ms, camera_id) do
    Enum.reduce(labels, %{}, fn {label, entry}, kept ->
      cond do
        Map.has_key?(seen, label) ->
          Map.put(kept, label, entry)

        entry.absent_since_ms == nil ->
          Map.put(kept, label, %{entry | absent_since_ms: at_ms})

        at_ms - entry.absent_since_ms < @clear_after_ms ->
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

  # The ledger write sits on whichever side of the emit keeps the recovery
  # clear AT LEAST once: insert before a started (a row exists once the
  # started may have gone out), delete after a cleared (the row survives
  # until the cleared has). A crash between either pair costs a duplicate
  # cleared, never a missing one.
  defp broadcast(:presence_started = kind, camera_id, label, entry) do
    Cairn.PresenceLedger.announced(camera_id, label, entry.first_seen_at, entry.best_score)
    emit(kind, camera_id, label, entry)
  end

  defp broadcast(:presence_cleared = kind, camera_id, label, entry) do
    emit(kind, camera_id, label, entry)
    Cairn.PresenceLedger.cleared(camera_id, label)
  end

  # Both halves of one transition: the cluster-wide broadcast every consumer
  # already reads, and a direct cast to this camera's event lane. The cast is
  # not a second subscriber to the topic on purpose — the trigger for a
  # recording must not race PubSub delivery, and it must reach exactly the one
  # process that owns this camera's events.
  defp emit(kind, camera_id, label, entry) do
    event = %PresenceEvent{
      camera_id: camera_id,
      label: label,
      score: entry.best_score,
      first_seen_at: entry.first_seen_at,
      at: DateTime.utc_now()
    }

    PresenceEvent.broadcast(kind, event)
    PresenceRecorder.presence(camera_id, kind, event)
  end
end
