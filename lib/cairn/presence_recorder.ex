defmodule Cairn.PresenceRecorder do
  @moduledoc """
  A tier-1 camera's event lifecycle — what that tier runs *instead of*
  `Cairn.CameraTracker`, and the only thing that turns presence into a
  recording.

  One process per camera, registered as `Cairn.Registry.via(camera_id,
  :presence_recorder)` and started beside the camera's
  `Cairn.PresenceAggregator` in `Cairn.PresenceSupervisor`'s pool. It is fed
  two streams, both direct casts from the same node (no PubSub on the trigger
  path):

    * **transitions**, from the aggregator, at the points it broadcasts a
      `Cairn.PresenceEvent`. A `presence_started` on a label the camera's
      `record:` tier admits opens an event; the close clock starts when the
      last such label clears. Labels the tier refuses neither open an event
      nor hold one open.
    * **frames**, from `Cairn.Pipeline.PresenceSink` — the full inferred
      frames, objects and boxes intact, which the aggregator never sees
      because it folds them to `%{label => score}`. While an event is open
      they are what gives a presence recording its trigger box, its label
      timeline and its dense bbox sidecar; while none is they are dropped,
      save the latest batch, which is held for the event it may be about to
      open (`frames/3`).

  What comes out is an ordinary `Cairn.Event`: the same
  `:event_started`/`:event_updated`/`:event_ended` broadcasts, the same
  `Cairn.EventExtractor` writing the same clip and the same persisted row, so
  `/api/events`, the SSE stream, retention and the event browser need to know
  nothing about presence. Nothing on the row marks the lane; the tier of its
  camera is the signal for anyone who cares.

  Two things are genuinely different from the tracked lane, both because there
  is no tracker:

    * **No identity.** The sidecar entries are keyed by label rather than by
      `object_id`, and the header declares that variant so the playback
      overlay colours by label (`Cairn.TrackPath`). Concurrent objects of one
      label get per-label render slots — separate paths, shared colour — but
      a slot is frame-to-frame continuity, never an identity claim
      (`assign_slots/2`).
    * **The post window is armed by a clear, not reset by evidence.** The
      tracked lane re-arms its post timer on every batch of evidence; here a
      label is *present* until the aggregator says otherwise, so the timer is
      scheduled when the last qualifying label clears and cancelled if one
      confirms again inside it.
    * **The max-event timer segments rather than stops** (Ben, 2026-08-20).
      At tier 2 the cap ends what a scene of evidence earned; here a label
      that is still present has nothing left to say — it confirms once and
      then simply *is* — so a cap that ended the recording would leave a
      standing presence with one clip and nothing after it. The cap therefore
      closes the clip and opens the next one from the labels still present
      (`resegment/2`), and the new clip's pre-window ring drain covers the
      boundary. The post window never reopens: it only fires with the present
      set empty, which is the scene being over.
    * **A failed open is retried on a timer.** At tier 2 the next batch of
      evidence opens the event a failed attempt owes; here a confirmed label
      never confirms twice, so nothing would ever come back to it and the whole
      stay would go unrecorded. An open that fails arms `arm_retry/1` instead,
      and the presence clearing is what ends the loop.

  The checkpoint is written to `Cairn.PresenceCheckpoint` and never to
  `Cairn.EventCheckpoint` — see that module for why the keyspaces must not
  meet. `init/1` reads it back: an extractor still alive is re-attached to
  (monitor, timers re-armed), a dead one leaves an orphan to end, and no row at
  all is checked against the event index for an extractor still writing without
  one — the state a `Cairn.PresenceCheckpoint` crash leaves, which nothing else
  would ever end (`sweep_stranded/1`). The `Cairn.PresenceLedger` is read there
  too — it is the aggregator's own announced set, and the only witness to a
  `presence_started` this process never saw because it was down when the cast
  went out.
  """

  use GenServer, restart: :transient

  require Logger

  alias Cairn.{
    CameraControl,
    Config,
    Event,
    Events,
    PresenceCheckpoint,
    PresenceEvent,
    PresenceLedger
  }

  @max_label_entries 5_000
  # Concurrent boxes the sidecar keeps per label per frame. The lane is
  # identity-free, so this bounds render slots, not tracks; two people and a
  # dog is the realistic ceiling for a presence camera, and every extra slot
  # is a sidecar column set an empty scene never pays for.
  @max_boxes_per_label 4
  # `Cairn.CameraTracker`'s throttle and for its reason: the row is a deep ETS
  # copy of the whole event, rewritten on every batch that says anything, and
  # what a second-stale copy costs is the last second of label entries on an
  # event that had to be restored. The writes a restore reads for its decisions
  # are exempt: the event's first and last, and every clear edge (`cleared/2`),
  # which is what tells the replacement whether the close clock was running.
  @checkpoint_throttle_ms 1_000
  # How long a batch held while idle may wait for the event it belongs to. The
  # aggregator confirms on two sightings inside its 2 s window, so the batch
  # that confirms is at most that old when the transition lands here; the rest
  # is mailbox slack. Anything older describes a scene this event was not
  # opened for.
  @pending_max_age_ms 3_000
  # One camera start's worth of patience for an adoptee that is dying — see
  # `adopt/3`. Small and bounded because the alternative to waiting is starting
  # a second recorder for a camera that still has one.
  @adopt_attempts 3
  @adopt_retry_ms 20
  # How long a lane waits before trying an open again after one failed
  # (`arm_retry/1`). Short against every window it competes with — the post
  # window's 10 s, the cap's 300 s — so a supervisor that was mid-restart is
  # tried again while the presence that wanted the clip is almost certainly
  # still there, and long enough not to spin on a supervisor that is down for
  # good. What bounds the loop is presence: the labels clearing ends it, and the
  # aggregator guarantees every started gets a cleared.
  @retry_open_ms 5_000

  @doc """
  Starts the recorder for one camera.

  `:camera_id` is required. `:name` defaults to this camera's registered
  via-tuple; `nil` starts it unregistered, which is how a test drives one
  directly. `:resolve_policy`, `:start_extractor`, `:finalize_extractor` and
  `:monotonic_ms` are injection seams documented at their defaults in
  `init/1`.
  """
  def start_link(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)

    case Keyword.get(opts, :name, Cairn.Registry.via(camera_id, :presence_recorder)) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  The recorder for `camera_id`, started under `Cairn.PresenceSupervisor.Pool`
  if it is not running yet.

  Called where the aggregator is ensured, so the two are always started
  together; a caller on the frame path uses `frames/3`, which never starts one.

  An existing recorder is **adopted, not merely found**: a camera restarting
  under a changed config stops (latching `retire/1`) and comes back still
  tier 1, and the recorder that outlived the stop for its open event is the one
  the new session gets. Un-latching it here is what keeps it: the latch is
  paid when the event closes, and this is the only call that says the camera
  came back. A camera that really left never reaches here again, so its latch
  still stops it.

  The un-latching is a **call**, and that is the whole point. The registry is a
  stale-read site and a `:retire` may already be in the mailbox ahead of us: a
  cast would be accepted by a process that then stops without ever handling it,
  and this function would hand back a pid the lane is about to lose — with
  nothing ever calling `ensure/1` again to notice. A reply proves the latch is
  off. An exit means the adoptee was dying, so the lookup is retried and a
  vacant registry starts a fresh recorder.
  """
  @spec ensure(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure(camera_id), do: ensure(camera_id, @adopt_attempts)

  defp ensure(camera_id, attempts) do
    case Cairn.Registry.whereis(camera_id, :presence_recorder) do
      pid when is_pid(pid) -> adopt(camera_id, pid, attempts)
      nil -> start_recorder(camera_id)
    end
  end

  # The sleep is affordable exactly here: this runs when a camera's presence
  # tree is being started, once, and never on the frame path. What it waits out
  # is the registry's unregistration, which rides the DOWN the partition sends
  # itself — so a corpse can still answer `whereis` for a moment after the
  # process that would have replied is gone.
  defp adopt(camera_id, pid, attempts) do
    :ok = GenServer.call(pid, :resume)
    {:ok, pid}
  catch
    :exit, _dying when attempts > 0 ->
      Process.sleep(@adopt_retry_ms)
      ensure(camera_id, attempts - 1)

    :exit, reason ->
      {:error, reason}
  end

  defp start_recorder(camera_id) do
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

  @doc """
  One presence transition, as the aggregator broadcast it.

  A missing recorder drops the transition rather than starting one: this runs
  inside the aggregator, whose own invariants must not depend on the lane
  being up.
  """
  @spec presence(String.t(), :presence_started | :presence_cleared, PresenceEvent.t()) :: :ok
  def presence(camera_id, kind, %PresenceEvent{} = event) do
    cast(camera_id, {:presence, kind, event})
  end

  @doc """
  One buffer's model-inferred frames, with the floors they were judged
  against.

  The frames are the sink's own — objects with boxes, before the fold to
  `%{label => score}` — and the recorder discards them unless an event is
  open. All but the latest: that one is held, because the sink casts here
  before the aggregator has finished with the same batch, so the batch that
  *confirms* presence always arrives ahead of the transition it causes. It is
  replayed into the event it opens (`@pending_max_age_ms`); without that, an
  event opened behind a closing motion gate could wait out its whole clip for
  a frame that never comes, and finalize with no trigger box and no sidecar.
  """
  @spec frames(String.t(), %{optional(String.t()) => float()}, [map()]) :: :ok
  def frames(camera_id, floors, frames) do
    cast(camera_id, {:frames, floors, frames})
  end

  @doc """
  The camera is going away: stop, unless an event is open.

  An open event outlives the retire — its clip is being written and its post
  window is what closes it — so this only latches, and the process stops when
  the event does. The aggregator retires this process first and flushes its own
  labels immediately after, so the cleareds that close the event are on their
  way here; the latch is also what keeps the cap from segmenting into a clip
  for a camera that is leaving (`resegment/2`).
  """
  @spec retire(String.t()) :: :ok
  def retire(camera_id), do: cast(camera_id, :retire)

  defp cast(camera_id, message) do
    case Cairn.Registry.whereis(camera_id, :presence_recorder) do
      nil -> :ok
      pid -> GenServer.cast(pid, message)
    end
  end

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)

    state = %{
      camera_id: camera_id,
      # Resolved here and again at every qualifying transition: `record:` is
      # the gate this process exists to apply, and an operator who edits it
      # should not have to wait for the next event to see it take.
      camera: nil,
      policy: nil,
      # The effective floors the sink judged the last frames against — the
      # runtime `min_score` override included, which the camera struct does
      # not carry. `nil` until the first buffer arrives, and kept by the idle
      # clause too: an open's own tier check is measured against them.
      floors: nil,
      # `{floors, frames, monotonic_ms}` — the last batch that arrived with no
      # event open, kept for `replay_pending/1`. At most one, replaced rather
      # than accumulated.
      pending: nil,
      event: nil,
      # `started_at` in unix milliseconds, so a frame's own `observed_at_ms`
      # places its boxes without a DateTime round trip per frame.
      started_unix_ms: nil,
      extractor: nil,
      extractor_ref: nil,
      # `monitor ref => event_id` for extractors told to finalize and not yet
      # exited: one per close, removed by the `:DOWN` that answers it. Kept
      # rather than demonitored so that a *failed* exit still reports itself —
      # see the second `:DOWN` clause.
      finalizing: %{},
      # True only for an extractor this process did not start — one adopted
      # from a checkpoint by `reattach/5`. What hangs on it is how its `:DOWN`
      # is read; see the handler.
      adopted_extractor?: false,
      present_labels: MapSet.new(),
      # Per-label render-slot centres from the last forwarded frame — see
      # assign_slots/3. Continuity state only; nothing decides on it. Rides
      # the checkpoint so a replacement recorder keeps the sidecar's paths.
      box_slots: %{},
      # Per-label per-event slot watermark: numbers only grow, so no slot id
      # is ever re-minted onto an unrelated earlier path.
      box_slot_next: %{},
      # The same set with each label's best score while it has been present,
      # which the event alone cannot answer once it has closed: a segment
      # opened at a `max_event` boundary is seeded from these.
      present_scores: %{},
      checkpointed_at: nil,
      post_ref: nil,
      post_token: nil,
      max_ref: nil,
      max_token: nil,
      # The open-retry loop's timer, armed only by a FAILED open — see
      # `arm_retry/1`. Presence itself is what bounds it.
      retry_ref: nil,
      retry_token: nil,
      retiring?: false,
      # The camera's `record:` tier and event windows, re-read at every
      # qualifying transition. Injectable because the config server is the
      # only way to reach a camera's tiers, and a test needs to drive one
      # without a config file behind it.
      resolve_policy: Keyword.get(opts, :resolve_policy, &policy_from_config/1),
      start_extractor: Keyword.get(opts, :start_extractor, &start_extractor/2),
      finalize_extractor:
        Keyword.get(opts, :finalize_extractor, &Cairn.EventExtractor.finalize/2),
      monotonic_ms: Keyword.get(opts, :monotonic_ms, &default_monotonic_ms/0)
    }

    {:ok, state |> resolve_policy() |> restore()}
  end

  # The identity variant is declared once, here, and travels with the event to
  # the sidecar's header: everything this lane forwards is label-keyed.
  defp start_extractor(camera, event) do
    Cairn.EventExtractor.start(camera, event, identity: :label)
  end

  @impl true
  def handle_cast({:presence, :presence_started, %PresenceEvent{} = presence}, state) do
    state = resolve_policy(state)

    if qualifies?(state, presence) do
      {:noreply, started(state, presence)}
    else
      {:noreply, state}
    end
  end

  # Membership, not the tier, decides: a label this process never admitted is
  # not in the set, so a clear for it falls out here without asking a question
  # whose answer (a `nil` score, an edited `record:` block) could differ from
  # the one asked when it started.
  def handle_cast({:presence, :presence_cleared, %PresenceEvent{} = presence}, state) do
    if MapSet.member?(state.present_labels, presence.label) do
      {:noreply, cleared(state, presence.label)}
    else
      {:noreply, state}
    end
  end

  # D-E5: the frames flow whether or not anything is recording, and are worth
  # nothing until something is — bar the latest batch, which is held for the
  # event it may be about to open (see `frames/3` and `replay_pending/1`).
  # One batch, replaced each time: an idle camera must stay O(1).
  def handle_cast({:frames, floors, frames}, %{event: nil} = state) do
    {:noreply, %{state | floors: floors, pending: {floors, frames, state.monotonic_ms.()}}}
  end

  def handle_cast({:frames, floors, frames}, state) do
    {:noreply, Enum.reduce(frames, %{state | floors: floors}, &frame/2)}
  end

  def handle_cast(:retire, %{event: nil} = state), do: {:stop, :normal, state}

  # Latched rather than stopped, because an event is open. The `cancel_retry/1`
  # is belt and braces: a retry is armed only with no event open, so nothing can
  # be pending in this clause today, and one nil check keeps that from becoming
  # a leak if a later path arms one.
  def handle_cast(:retire, state),
    do: {:noreply, cancel_retry(%{state | retiring?: true})}

  # The camera came back — see `ensure/1`. A recorder that stopped on its latch
  # is replaced there instead; this is only for the one that could not, because
  # its event was still open. The reply is the contract: it is what tells the
  # caller this process handled the un-latching rather than dying with it
  # queued.
  @impl true
  def handle_call(:resume, _from, state), do: {:reply, :ok, %{state | retiring?: false}}

  @impl true
  def handle_info({:post_window, event_id, token}, state) do
    # the token guards a stale timer message that was already in the mailbox
    # when a fresh `presence_started` cancelled the window
    if token == state.post_token do
      settle(maybe_finalize(state, event_id, :post_window))
    else
      {:noreply, state}
    end
  end

  def handle_info({:max_event, event_id, token}, state) do
    if token == state.max_token do
      settle(maybe_finalize(state, event_id, :max_event))
    else
      {:noreply, state}
    end
  end

  # The token pattern the windows use, for its reason: a retry already in the
  # mailbox when a transition opened the event (and cancelled the loop) is
  # judged against a cleared token and dropped.
  def handle_info({:retry_open, token}, %{retry_token: token} = state) do
    {:noreply, retry_open(%{state | retry_ref: nil, retry_token: nil})}
  end

  def handle_info({:retry_open, _stale}, state), do: {:noreply, state}

  # An exit while the event is open ends it `:partial`, whatever the reason —
  # `:normal` and `:noproc` included. `Cairn.CameraTracker` reads those two as
  # a clean finish; that rule belongs to an extractor it adopted from a
  # checkpoint, and for an extractor this process started itself a
  # clean-looking reason is one that died before doing its work, where clearing
  # silently would strand the checkpoint row, the `:active` DB row and every
  # `:event_ended` subscriber. The exit that FOLLOWS a finalize is the clause
  # below, not this one: `clear_event/1` moved that monitor to `finalizing`.
  #
  # An ADOPTED extractor is the case CameraTracker's rule was written for, and
  # gets it: the process that started it crashed, so its finalize may have been
  # in flight when this one restored the row, and the index — which the
  # extractor itself wrote — is what says whether that is what happened.
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{extractor: pid} = state) do
    case state.event do
      %Event{} = event ->
        PresenceCheckpoint.delete(state.camera_id)

        if finished_before_restore?(state, event) do
          Logger.info("event #{event.id}: the adopted extractor had already finalized it")
        else
          Logger.warning("event #{event.id}: extractor exited open (#{inspect(reason)})")
          Event.broadcast(:event_ended, %{event | status: :partial, ended_at: now()})
        end

        # The stay is not over just because its clip is: an extractor answers
        # `{:ok, pid}` from `start_link` and opens its row and its file in a
        # `handle_continue`, so a failure there — or any death mid-clip —
        # arrives here, and presence will not trigger again for a label it
        # already holds. The retry re-checks every gate when it fires.
        settle(arm_retry(clear_event(%{state | extractor_ref: nil})))

      nil ->
        settle(clear_event(%{state | extractor_ref: nil}))
    end
  end

  # The exit of an extractor that was already told to finalize. Expected, and
  # silent when it looks like one — but an abnormal reason here is a clip that
  # failed on its way out (a mux or write error after the finalize cast), and
  # nothing else in the system would say so. With the cap segmenting, a camera
  # holding presence hands over an extractor this way every `max_event`, so a
  # recurring write failure would otherwise be invisible for as long as it
  # lasted.
  #
  # Nothing is broadcast either way: `:event_ended` went out before the finalize
  # cast (`maybe_finalize/3`), and a row the extractor never closed stays
  # `:active` for boot reconciliation to mark partial.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.finalizing, ref) do
      {nil, _finalizing} ->
        {:noreply, state}

      {event_id, finalizing} ->
        unless reason in [:normal, :noproc] do
          Logger.warning("event #{event_id}: extractor exited #{inspect(reason)} after finalize")
        end

        {:noreply, %{state | finalizing: finalizing}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # A retire that arrived with an event open latched instead of stopping; this
  # is where it is paid, once the event that outranked it has closed.
  defp settle(%{retiring?: true, event: nil} = state), do: {:stop, :normal, state}
  defp settle(state), do: {:noreply, state}

  # -- transitions ------------------------------------------------------------

  defp started(state, presence),
    do: admit(state, [{presence.label, presence.score}], presence.first_seen_at, presence.at)

  # Qualifying labels becoming present: they hold an event open (so any close
  # clock stops) and they either extend the open one or open a new one.
  # `started_at` is consulted only in that second case, and the callers differ
  # on it — a confirm dates the event from `first_seen_at`, because presence is
  # confirmed on the second sighting and the event began at the first, while
  # `adopt_announced/1` can only date one from now (see there).
  defp admit(state, seeds, started_at, at) do
    state =
      seeds
      |> Enum.reduce(state, fn {label, score}, acc -> track_present(acc, label, score) end)
      |> cancel_post()

    cond do
      state.event != nil ->
        Enum.reduce(seeds, state, fn {label, score}, acc -> merge_label(acc, label, score, at) end)

      recording_enabled?(state) ->
        start_event(state, started_at, seeds)

      true ->
        state
    end
  end

  defp track_present(state, label, score) do
    %{
      state
      | present_labels: MapSet.put(state.present_labels, label),
        present_scores: merge_score(state.present_scores, label, score)
    }
  end

  # The checkpoint is written on the edge and past the throttle, the rule the
  # event's own first and last writes follow: what a clear changes is which
  # labels the row still names and whether the close clock is running, which is
  # exactly what a restore has to be told and what a throttled write can be a
  # second late with.
  defp cleared(state, label) do
    present = MapSet.delete(state.present_labels, label)

    state = %{
      state
      | present_labels: present,
        present_scores: Map.delete(state.present_scores, label)
    }

    # The retry loop runs only while a present label is owed a clip, so the
    # last one leaving is what ends it — the bound `arm_retry/1` relies on.
    state = if MapSet.size(present) == 0, do: cancel_retry(state), else: state

    cond do
      state.event == nil -> state
      # The last qualifying label left: the only thing that starts the close
      # clock, so an event whose labels never clear runs to `max_event`.
      MapSet.size(present) == 0 -> state |> write_checkpoint() |> arm_post()
      true -> write_checkpoint(state)
    end
  end

  # `started_at` is the event's t=0, and every box's `t_ms` is measured from it;
  # `seeds` are the labels it opens with, at the best score known for each.
  defp start_event(state, started_at, seeds) do
    max_scores = Map.new(seeds)

    event = %Event{
      id: Ecto.UUID.generate(),
      camera_id: state.camera_id,
      started_at: started_at,
      status: :active,
      labels: for({label, score} <- seeds, do: label_entry(label, score, 0)),
      max_scores: max_scores,
      max_score: best_score(max_scores),
      # No box at a confirm — the aggregator carries none, and a segment
      # boundary is not an observation either. The first frame that arrives
      # while this is open sets it (`best_trigger/3`), and an event that sees
      # none falls back to `Cairn.Snapshot`'s boxless path.
      trigger: nil
    }

    case launch_extractor(state, event) do
      {:ok, pid} ->
        PresenceCheckpoint.put(state.camera_id, event, MapSet.to_list(state.present_labels), pid)
        Event.broadcast(:event_started, event)
        {max_ref, max_token} = schedule(:max_event, event.id, state.policy.max)
        state = cancel_retry(state)

        replay_pending(%{
          state
          | event: event,
            started_unix_ms: DateTime.to_unix(started_at, :millisecond),
            checkpointed_at: state.monotonic_ms.(),
            extractor: pid,
            extractor_ref: Process.monitor(pid),
            adopted_extractor?: false,
            max_ref: max_ref,
            max_token: max_token
        })

      {:error, reason} ->
        Logger.error("camera #{state.camera_id}: could not start extractor: #{inspect(reason)}")
        arm_retry(state)
    end
  end

  # `Cairn.EventExtractor.start/3` is a `DynamicSupervisor.start_child/2`, so it
  # *exits* when `Cairn.EventSupervisor` is inside its own restart window —
  # `policy_from_config/1`'s hazard, and worse here, because `restore/1` can
  # reach this from `init/1`: a crash there is re-driven by the `:transient`
  # restart, deterministically, since the ledger row that led to it is not
  # consumed by reading it. Such a loop spends the pool's restart intensity in
  # seconds, and `:rest_for_one` takes both presence tables down with the pool.
  #
  # The state a refusal leaves is a consistent one — labels present, no event —
  # and the next qualifying transition opens from it.
  # Normalized to two shapes because the seam's default is
  # `DynamicSupervisor.start_child/2`, whose contract also allows
  # `{:ok, pid, info}` and `:ignore` — either would otherwise crash the one
  # caller's case, inside `init/1` on the adoption path.
  defp launch_extractor(state, event) do
    case state.start_extractor.(state.camera, event) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      :ignore -> {:error, :ignore}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # A second label confirming while an event is open extends it rather than
  # opening a second one (one event per camera, labels merged). The frames do
  # this too, per detection; doing it here as well puts the label on the row at
  # the moment the lane admitted it rather than at whatever later frame the
  # motion gate lets through — a still scene delivers none at all.
  defp merge_label(state, label, score, at) do
    event = state.event
    new_label? = not Map.has_key?(event.max_scores, label)
    t_ms = DateTime.diff(at, event.started_at, :millisecond)
    max_scores = merge_score(event.max_scores, label, score)

    event = %{
      event
      | labels: take_entries(event.labels, [label_entry(label, score, t_ms)]),
        max_scores: max_scores,
        max_score: best_score(max_scores)
    }

    state = checkpoint(%{state | event: event})
    if new_label?, do: Event.broadcast(:event_updated, event)
    state
  end

  # -- frames -----------------------------------------------------------------

  # The batch held while idle, given to the event that just opened. It is
  # almost always the batch that *caused* the open: the sink casts frames here
  # and the same batch's `observed` to the aggregator, whose confirm then
  # travels back as the transition — so this process sees the frames first, at
  # a moment when it has nothing to do with them.
  #
  # Dropped either way. A batch too old to replay is one this event was not
  # opened for; the age is measured, not assumed, because a gated scene can
  # leave the last batch minutes behind.
  defp replay_pending(%{pending: nil} = state), do: state

  defp replay_pending(%{pending: {floors, frames, at_ms}} = state) do
    state = %{state | pending: nil}

    if state.monotonic_ms.() - at_ms <= @pending_max_age_ms do
      Enum.reduce(frames, %{state | floors: floors}, &frame/2)
    else
      state
    end
  end

  # `t_ms` can be negative: the frame is dated by the engine's capture clock
  # and the event by the confirm that followed one, so a frame captured before
  # that confirm and delivered after it lands before the event's t=0 — inside
  # the pre-roll the clip holds, which is where its boxes belong. The sidecar's
  # axis is signed for it; the label and trigger times clamp at zero, being
  # offsets into an event rather than into a clip.
  defp frame(frame, state) do
    t_ms = frame_unix_ms(frame) - state.started_unix_ms
    objects = Map.get(frame, :objects, [])

    slots_before = {state.box_slots, state.box_slot_next}
    state = forward_boxes(state, t_ms, objects)
    state = fold(state, Enum.filter(objects, &qualifying_object?(state, &1)), t_ms)

    # Slot state must reach the checkpoint even when the frame carried no
    # qualifying detection: predicted and below-floor boxes still move the
    # centres and the watermark, and a crash would otherwise restore paths
    # from wherever the last qualifying frame left them. Throttled by
    # checkpoint/1 like every other write.
    if state.event != nil and {state.box_slots, state.box_slot_next} != slots_before do
      checkpoint(state)
    else
      state
    end
  end

  # The dense half of the playback overlay, in the compact shape
  # `Cairn.TrackPath` reads. Deliberately unfiltered — no floor, no `record:`
  # tier — for the tracked lane's reason: what earns video is a different
  # question from what is drawn over video already recorded.
  #
  # A path's id is the label plus a render slot (D-E5b amended): with no
  # tracker there is no identity to key by, so concurrent same-label boxes go
  # to slots matched against the previous frame's centres — up to
  # @max_boxes_per_label of them, best scores first when the frame offers
  # more. Slot 0 keeps the bare label, so a single-subject file reads exactly
  # as v1 did.
  #
  # **Ordering dependency**, `Cairn.CameraTracker.forward_boxes/2`'s: this cast
  # and the finalize cast in `maybe_finalize/3` share a sender and a receiver,
  # so every box sent before finalize is in the extractor's mailbox before it.
  # A `call`, or a finalize routed through another process, silently truncates
  # the sidecar's tail.
  defp forward_boxes(%{extractor: pid} = state, t_ms, objects) when is_pid(pid) do
    {boxes, slots, next} =
      objects
      |> Enum.filter(&boxed?/1)
      |> Enum.group_by(& &1.label)
      |> Enum.reduce({[], %{}, state.box_slot_next}, fn {label, dets}, {boxes, slots, next} ->
        {assigned, centers, label_next} =
          dets
          |> Enum.sort_by(& &1.score, :desc)
          |> Enum.take(@max_boxes_per_label)
          |> assign_slots(
            Map.get(state.box_slots, label, %{}),
            Map.get(next, label, 0)
          )

        entries = for {slot, det} <- assigned, do: box_entry(label, slot, det)

        {entries ++ boxes, Map.put(slots, label, centers), Map.put(next, label, label_next)}
      end)

    # The watermark is persisted BEFORE the first box wearing a new id
    # reaches the extractor, and unthrottled: once the sidecar holds the
    # id, a crash restoring a pre-mint checkpoint would re-mint it onto
    # an unrelated subject. Mints are rare (bounded per label per event);
    # centre-only movement stays on the throttled path in `frame/2`.
    minted? = next != state.box_slot_next
    state = %{state | box_slots: slots, box_slot_next: next}
    state = if minted?, do: write_checkpoint(state), else: state

    if boxes != [] do
      GenServer.cast(pid, {:track_boxes, %{t_ms: t_ms, boxes: boxes}})
    end

    state
  end

  defp forward_boxes(state, _t_ms, _objects), do: state

  # The lane has no tracker, so a slot is not an identity — it is render
  # continuity: the overlay interpolates between a sidecar track's samples,
  # and two concurrent people swapping tracks between keyframes would draw
  # boxes gliding through each other. Matching is maximum-cardinality first
  # (then minimum total centre distance): greedy in score order could mint a
  # new path even when a one-to-one match existed for every box — prev
  # centres 0.20/0.55 with a high-score det at 0.35 and another at 0.00
  # would greedily take 0.20's slot for 0.35 and mint for 0.00, the exact
  # discontinuity slots exist to prevent. At most four boxes and four slots,
  # so exhaustive search costs nothing; a wrong guess costs one crossing
  # artifact, never a detection.
  #
  # A slot only claims a box in its neighbourhood: normalized centre distance
  # above @slot_match_radius reads as "someone else", and the box mints a
  # fresh slot rather than yanking an existing path across the frame.
  @slot_match_radius 0.25

  defp assign_slots(dets, prev_centers, next0) do
    candidates =
      for det <- dets do
        center = box_center(det.bbox)

        options =
          prev_centers
          |> Enum.map(fn {slot, prev} -> {slot, center_distance(center, prev)} end)
          |> Enum.filter(fn {_slot, d} -> d <= @slot_match_radius end)

        {det, center, options}
      end

    {_count, _dist, assigned} = best_assignment(candidates, [])

    # New slots number from a per-event watermark and a number is NEVER
    # reused — not the just-vacated slot of a subject that jumped past the
    # radius, and not a slot retired frames ago: `TrackPath.collect/1`
    # groups event-wide by id, so a re-minted number would splice this box
    # onto an unrelated earlier path and the overlay would interpolate
    # across the frame. A label re-entering after absence starts a fresh
    # path for the same reason; more sidecar tracks, never a false glide.
    {numbered, next} =
      Enum.map_reduce(assigned, next0, fn
        {:new, det, center}, next -> {{next, det, center}, next + 1}
        {slot, det, center}, next -> {{slot, det, center}, next}
      end)

    {Enum.map(numbered, fn {slot, det, _c} -> {slot, det} end),
     Map.new(numbered, fn {slot, _det, center} -> {slot, center} end), next}
  end

  defp center_distance({cx, cy}, {px, py}), do: abs(cx - px) + abs(cy - py)

  # Exhaustive over ≤4 dets x ≤4 in-radius slot options each: every det
  # either takes an unclaimed slot or goes :new, maximizing matches and
  # breaking ties by total distance.
  defp best_assignment([], _used), do: {0, 0.0, []}

  defp best_assignment([{det, center, options} | rest], used) do
    {c, d, ch} = best_assignment(rest, used)
    start = {c, d, [{:new, det, center} | ch]}
    Enum.reduce(options, start, &consider_slot(&1, &2, det, center, rest, used))
  end

  defp consider_slot({slot, dist}, {best_c, best_d, _} = best, det, center, rest, used) do
    if slot in used do
      best
    else
      {c1, d1, ch1} = best_assignment(rest, [slot | used])

      if c1 + 1 > best_c or (c1 + 1 == best_c and d1 + dist < best_d) do
        {c1 + 1, d1 + dist, [{slot, det, center} | ch1]}
      else
        best
      end
    end
  end

  defp box_center([x, y, w, h]), do: {x + w / 2, y + h / 2}

  # Slot 0 keeps the bare label as its id — the exact id every v1 presence
  # sidecar used — so a reader keying on it sees no new world; extra
  # concurrent boxes suffix their slot. `identity: "label"` readers colour
  # and select by `label` either way.
  # A plugin-predicted box rides the dense-capture rule like any other
  # (drawn, never evidence), but its score is the last real detection's —
  # forwarding it would re-stamp a stale claim, so it writes the same
  # no-score sentinel the tracked lane's coasted boxes do. The numeric
  # score still ranks it for slot assignment: ranking is render policy,
  # not a claim.
  defp box_entry(label, slot, det) do
    score = if Cairn.Observation.detected?(det), do: det.score
    {slot_id(label, slot), label, det.bbox, false, score}
  end

  # 0x1F (unit separator) because labels are arbitrary PRINTABLE strings:
  # a label literally named "person/1" is legal and would collide with a
  # "/"-joined id — `TrackPath.collect/1` groups event-wide by id, and the
  # collision would merge two subjects' samples into one path. No printable
  # label can contain 0x1F. Slot 0 keeps the bare label (v1's shape).
  defp slot_id(label, 0), do: label
  defp slot_id(label, slot), do: label <> <<0x1F>> <> Integer.to_string(slot)

  defp fold(state, [], _t_ms), do: state

  defp fold(state, dets, t_ms) do
    event = state.event
    known = event.max_scores

    max_scores =
      Enum.reduce(dets, known, fn det, acc -> merge_score(acc, det.label, det.score) end)

    entries = for det <- dets, do: label_entry(det.label, det.score, t_ms)

    event = %{
      event
      | labels: take_entries(event.labels, entries),
        max_scores: max_scores,
        max_score: best_score(max_scores),
        trigger: best_trigger(event.trigger, dets, t_ms)
    }

    state = checkpoint(%{state | event: event, present_scores: better_scores(state, dets)})

    # Only a label the event had not seen: a frame rate's worth of
    # `:event_updated` per second would be a firehose, and what a subscriber
    # cannot learn any other way is that the event grew a label.
    if map_size(max_scores) > map_size(known) do
      Event.broadcast(:event_updated, event)
    end

    state
  end

  # A present label's score improving where the frames can see it. The
  # transition that admitted the label carries the score as of its confirm, and
  # the event's own `max_scores` go with the event when it closes — so without
  # this the clip a cap segments into would open at a score the scene had left
  # behind. Only labels already present: a detection the aggregator has not
  # confirmed is evidence for the open event, not presence.
  defp better_scores(state, dets) do
    Enum.reduce(dets, state.present_scores, fn det, acc ->
      if MapSet.member?(state.present_labels, det.label),
        do: merge_score(acc, det.label, det.score),
        else: acc
    end)
  end

  # The event's single highest-scoring detection, kept with its bbox and time
  # offset — the frame `Cairn.Snapshot` cuts from and draws the box on. Keeps
  # the incumbent on ties, so the earliest such detection wins.
  #
  # A detection whose box is missing or malformed is passed over rather than
  # promoted: it counts toward the labels and scores like any other, but the
  # trigger is a box to draw, and one that is not a box would cost the snapshot
  # the frame it was cut at (`Cairn.Snapshot` falls back to the clip's first
  # frame when the trigger is unusable). The same shape `forward_boxes/3`
  # admits, for the same reason.
  defp best_trigger(current, dets, t_ms) do
    t = Float.round(max(t_ms / 1000, 0.0), 2)

    dets
    |> Enum.filter(&boxed?/1)
    |> Enum.reduce(current, fn det, best ->
      if is_nil(best) or det.score > best.score do
        %{t: t, label: det.label, score: det.score, bbox: det.bbox, object_id: nil}
      else
        best
      end
    end)
  end

  defp boxed?(object), do: match?(%{bbox: [_, _, _, _]}, object)

  # -- lifecycle --------------------------------------------------------------

  defp maybe_finalize(%{event: %Event{id: event_id} = event} = state, event_id, cause) do
    Logger.info("event #{event.id} (#{state.camera_id}): finalizing (#{cause})")
    event = %{event | ended_at: now(), status: :finalized}
    # Ended first, then the extractor is told — `Cairn.CameraTracker`'s
    # ordering, load-bearing twice over: a subscriber learns the window closed
    # before it learns the clip landed, and the cast puts every
    # `{:track_boxes, _}` this process already sent ahead of the finalize in
    # the same mailbox.
    Event.broadcast(:event_ended, event)
    state.finalize_extractor.(state.extractor, event)
    PresenceCheckpoint.delete(state.camera_id)

    state |> clear_event() |> resegment(cause)
  end

  defp maybe_finalize(state, _event_id, _cause), do: state

  # The cap is segmentation, not a stop (moduledoc): labels still present get
  # the next clip. `retiring?` is the exception — a camera on its way out gets
  # no new clips, and the cleareds its aggregator flushed are already in this
  # mailbox.
  #
  # The present set is answered by `Cairn.PresenceLedger` and not by this
  # process's own mirror of it. The mirror is maintained by casts, and a
  # `presence_cleared` cast lost while this process was restarting (or emitted
  # by an aggregator whose own restart found no recorder to tell) would leave a
  # label present here forever — which, with a cap that reopens, is a clip every
  # `max_event` seconds for as long as the camera streams. The ledger is the
  # aggregator's own announced set, so it settles the disagreement; when the
  # ledger itself was lost, its silence costs the continuation of one event
  # rather than an unbounded chain of them.
  defp resegment(%{retiring?: true} = state, _cause), do: state

  defp resegment(state, :max_event) do
    # The gate is re-read here for the reason it is re-read at a transition: a
    # boundary opens an event, and neither a `record:` block an operator has
    # since narrowed nor a raised floor should be found out about one whole
    # clip late.
    state = resolve_policy(state)
    seeds = open_seeds(state)

    if seeds != [] and recording_enabled?(state) do
      Logger.info("camera #{state.camera_id}: presence holds past the cap — segmenting")
      # `now/0`, not the labels' first-seen: this clip begins at this instant,
      # and its only reach into the past is the ring's pre-window.
      start_event(state, now(), seeds)
    else
      state
    end
  end

  defp resegment(state, _cause), do: state

  # What an open that is not driven by a transition may open with: the labels
  # this process holds as present, minus the ones the aggregator no longer
  # announces, minus the ones the gate no longer admits. Shared by the cap's
  # segmentation and the retry loop, which owe the same answer.
  defp open_seeds(state) do
    state.present_scores
    |> Map.take(announced_labels(state))
    |> Enum.filter(fn {label, score} -> earns_video?(state, label, score) end)
  end

  # An open that failed while the scene is still there. Presence gives no second
  # trigger — a confirmed label stays confirmed and never confirms again — so
  # without this a camera whose extractor could not start records nothing for
  # the whole stay, however long the person stands in front of it.
  #
  # Nothing arms this but a failure, and the retry re-runs every gate, so the
  # loop ends the moment there is an event, no presence, or no permission to
  # record.
  defp arm_retry(%{retiring?: true} = state), do: state

  defp arm_retry(state) do
    if MapSet.size(state.present_labels) == 0 do
      state
    else
      state = cancel_retry(state)
      token = make_ref()
      ref = Process.send_after(self(), {:retry_open, token}, @retry_open_ms)
      %{state | retry_ref: ref, retry_token: token}
    end
  end

  defp cancel_retry(%{retry_ref: nil} = state), do: state

  defp cancel_retry(state) do
    Process.cancel_timer(state.retry_ref)
    %{state | retry_ref: nil, retry_token: nil}
  end

  # The retry itself, through the same gates a segmentation boundary passes:
  # the camera may have been retired, something may have opened an event in the
  # meantime, recording may have been switched off, the policy may have
  # narrowed, and the presence that wanted the clip may have ended. A failure
  # here arms the next one from `start_event/3`; anything else lets the loop
  # stop.
  defp retry_open(%{retiring?: true} = state), do: state
  defp retry_open(%{event: %Event{}} = state), do: state

  defp retry_open(state) do
    state = resolve_policy(state)

    with true <- recording_enabled?(state),
         [_ | _] = seeds <- open_seeds(state) do
      Logger.info("camera #{state.camera_id}: retrying the open a failed one owes")
      # Dated now, `adopt_announced/1`'s reason: the clip can only begin here.
      start_event(state, now(), seeds)
    else
      _no_reason_to_open -> state
    end
  end

  defp clear_event(state) do
    if state.post_ref, do: Process.cancel_timer(state.post_ref)
    if state.max_ref, do: Process.cancel_timer(state.max_ref)

    %{
      state
      | event: nil,
        started_unix_ms: nil,
        extractor: nil,
        extractor_ref: nil,
        finalizing: retain_monitor(state),
        adopted_extractor?: false,
        checkpointed_at: nil,
        post_ref: nil,
        post_token: nil,
        max_ref: nil,
        max_token: nil,
        # Slot centres and the watermark are per-event render continuity;
        # carried across a close, a stale centre or watermark could hand
        # the next event's lone subject a nonzero slot and write a sidecar
        # with no bare-label track.
        box_slots: %{},
        box_slot_next: %{}
    }
  end

  # An extractor let go of while it is still alive has been told to finalize and
  # owes an exit; its monitor is carried into `finalizing` so that exit is
  # recognised instead of falling into the catch-all unlogged. The caller clears
  # `extractor_ref` first when the exit is what brought it here.
  defp retain_monitor(%{extractor_ref: nil} = state), do: state.finalizing
  defp retain_monitor(%{event: nil} = state), do: state.finalizing

  defp retain_monitor(state), do: Map.put(state.finalizing, state.extractor_ref, state.event.id)

  defp arm_post(state) do
    state = cancel_post(state)
    {post_ref, post_token} = schedule(:post_window, state.event.id, state.policy.post)
    %{state | post_ref: post_ref, post_token: post_token}
  end

  # Clearing the token as well as the timer is what makes the cancel total: a
  # `:post_window` already in the mailbox is judged against it and dropped.
  defp cancel_post(%{post_ref: nil} = state), do: state

  defp cancel_post(state) do
    Process.cancel_timer(state.post_ref)
    %{state | post_ref: nil, post_token: nil}
  end

  defp schedule(kind, event_id, seconds) do
    token = make_ref()
    tref = Process.send_after(self(), {kind, event_id, token}, seconds * 1_000)
    {tref, token}
  end

  defp checkpoint(state) do
    now = state.monotonic_ms.()

    if state.checkpointed_at == nil or now - state.checkpointed_at >= @checkpoint_throttle_ms do
      write_checkpoint(state)
    else
      state
    end
  end

  defp write_checkpoint(state) do
    PresenceCheckpoint.put(
      state.camera_id,
      state.event,
      MapSet.to_list(state.present_labels),
      state.extractor,
      %{centers: state.box_slots, next: state.box_slot_next}
    )

    %{state | checkpointed_at: state.monotonic_ms.()}
  end

  # -- restore ----------------------------------------------------------------

  # What a replacement for a dead recorder owes this camera, in
  # `Cairn.CameraTracker.restore_from_checkpoint/1`'s shape plus the ledger
  # read the tracked lane has no analogue of.
  #
  # This runs inside `init/1`, and two things follow. Nothing may call the
  # presence pool from here — `ensure/1`'s `DynamicSupervisor.start_child/2`
  # would block until it timed out when the pool is inside its own restart of
  # this process, the deadlock `Cairn.PresenceAggregator.init/1` documents;
  # nothing below reaches it (an extractor is started under
  # `Cairn.EventSupervisor`, a different tree). And an `ensure/1` `:resume` call
  # can already be queued behind the start: a GenServer serves calls only after
  # `init/1` returns, so it waits this out rather than racing it.
  defp restore(state) do
    state |> restore_checkpoint() |> adopt_announced()
  end

  defp restore_checkpoint(state) do
    case PresenceCheckpoint.get(state.camera_id) do
      nil ->
        sweep_stranded(state)

      {event, labels, extractor, box_slots} ->
        if is_pid(extractor) and Process.alive?(extractor) do
          reattach(state, event, labels, extractor, box_slots)
        else
          orphan(state, event)
        end
    end
  end

  # The extractor outlived the process that started it, so the clip is still
  # being written and this process adopts it rather than abandoning a live
  # recording.
  #
  # The post window restarts rather than resumes: the row does not carry how
  # much of it had run. The cap is different — the event's `started_at` says
  # exactly how much it has spent, so the timer gets the REMAINDER: a full
  # re-arm would let every restart stretch a clip another `max_event_seconds`
  # past the advertised cap. Zero or less fires now — the cap closes and
  # `resegment/2` keeps the coverage. Policy is the camera's own, since
  # `resolve_policy/1` has already run (`Cairn.CameraTracker` restores off the
  # global defaults because its camera is not resolved that early) — and it
  # degrades to the defaults by itself when the config server cannot answer.
  defp reattach(state, event, labels, extractor, box_slots) do
    Logger.info("event #{event.id} (#{state.camera_id}): re-attached to a live extractor")
    spent = DateTime.diff(now(), event.started_at, :second)
    {max_ref, max_token} = schedule(:max_event, event.id, max(state.policy.max - spent, 0))
    announced = announced_scores(state)
    present = still_announced(labels, announced)

    state = %{
      state
      | event: event,
        started_unix_ms: DateTime.to_unix(event.started_at, :millisecond),
        extractor: extractor,
        extractor_ref: Process.monitor(extractor),
        adopted_extractor?: true,
        present_labels: present,
        present_scores: restored_scores(present, announced, event.max_scores),
        # Slot continuity survives the crash with the row: the adopted
        # extractor is still buffering the same sidecar, and a replacement
        # that re-minted slot ids from zero could connect a new box to an
        # unrelated pre-crash path and interpolate across the frame. The
        # centers are at most a checkpoint-throttle stale — inside the
        # match radius for anything that hasn't genuinely moved on. The
        # watermark rides too: numbers allocated before the crash stay
        # retired.
        box_slots: Map.get(box_slots, :centers, %{}),
        box_slot_next: Map.get(box_slots, :next, %{}),
        checkpointed_at: state.monotonic_ms.(),
        max_ref: max_ref,
        max_token: max_token
    }

    # An empty present set means the close clock should be running: either the
    # row was written by `cleared/2`, which checkpoints that edge past the
    # throttle, or every label it named turned out to be a ghost. Nothing else
    # is coming to start that clock.
    if MapSet.size(present) == 0, do: arm_post(state), else: state
  end

  # The checkpoint's labels, minus the ones the aggregator no longer announces.
  # A label can survive in the row and not in the ledger: the aggregator emitted
  # its `presence_cleared` — deleting the ledger row — while the recorder that
  # would have recorded it was dying, so the cast died with the pid. Restoring
  # such a label makes it permanent (only a fresh confirm-and-clear cycle of
  # that same label would remove it), and since the post window is armed by the
  # LAST label leaving, one ghost keeps every later event on the camera running
  # to the cap.
  #
  # The ledger being empty for another reason costs little, and
  # `Cairn.PresenceSupervisor`'s `:rest_for_one` is why: the table sits ahead of
  # the pool, so rows lost with it are lost together with the aggregator that
  # announced them. That aggregator comes back blank and re-confirms whatever is
  # still in front of the camera, which cancels the post window this arms.
  defp still_announced(labels, announced) do
    labels |> Enum.filter(&Map.has_key?(announced, &1)) |> MapSet.new()
  end

  # The ledger's score for a restored label, not the event's. `max_scores` is
  # the best over the whole EVENT — a label that cleared low and came back, or
  # came back lower, keeps the old number there — while the ledger row is the
  # current stay's, improved as the aggregator sees better
  # (`Cairn.PresenceAggregator.sighted/5`), including everything it saw while
  # this process was down. It is what a segment opened from these labels should
  # claim. The event's number stands in for a row that carries none.
  #
  # A label with no number anywhere is left out rather than stored as `nil`:
  # `merge_score/3` improves a score with `max/2`, and Elixir's term order puts
  # an atom above every number, so a `nil` there would survive every real score
  # for the rest of the stay.
  defp restored_scores(present, announced, event_scores) do
    Enum.reduce(present, %{}, fn label, scores ->
      case current_score(label, announced, event_scores) do
        score when is_number(score) -> Map.put(scores, label, score)
        _unscored -> scores
      end
    end)
  end

  defp current_score(label, announced, event_scores) do
    case Map.get(announced, label) do
      score when is_number(score) -> score
      _unscored -> Map.get(event_scores, label)
    end
  end

  # No checkpoint row is the ordinary case — a camera with nothing open — and
  # one supervision accident makes it a lie. `Cairn.PresenceSupervisor` is
  # `:rest_for_one` with the tables ahead of the pool, so a
  # `Cairn.PresenceCheckpoint` crash takes the ledger, the aggregators and the
  # recorders with it, while the extractors, which live under
  # `Cairn.EventSupervisor`, keep writing: both witnesses to their events are
  # gone at once. Nothing else would ever end them — an extractor has no cap of
  # its own — and the camera's next confirm would open a SECOND one beside each.
  # What is left to find them by is the `:active` index row the extractor wrote
  # and its own registration under `{:extractor, event_id}`.
  #
  # Ended, not adopted: with no checkpoint there are no labels, no scores and no
  # trigger to carry on with, so adopting would mean guessing what the clip is
  # of. `:partial` is what such an event honestly is, and a presence that is
  # still there opens a fresh one through `adopt_announced/1` two lines later —
  # the coverage that actually matters. Rows whose extractor is gone are left
  # alone: boot reconciliation owns those.
  #
  # One residual, accepted rather than engineered around: both lanes delete
  # their checkpoint row immediately after casting the finalize, so a recorder
  # starting inside that window finds an extractor mid-finalize and sweeps it.
  # The cost is bounded to one spurious `:event_ended{status: :partial}` — the
  # extractor stops `:normal` once it has finalized, so this second cast dies
  # with the process and never touches the row, and the index keeps what the
  # extractor wrote. `event_ended` is at-least-once and consumers re-fetch by id
  # (docs/ha-api.md), so DB truth corrects it. A witness for "finalizing" would
  # cost every close a write to buy that back.
  defp sweep_stranded(state) do
    tracked = tracked_event_id(state.camera_id)

    state.camera_id
    |> active_rows()
    |> Enum.reject(&(&1.id == tracked))
    |> Enum.each(fn row ->
      case Cairn.Registry.whereis(state.camera_id, {:extractor, row.id}) do
        nil -> :ok
        extractor -> end_stranded(state, row, extractor)
      end
    end)

    state
  end

  # The row a `Cairn.CameraTracker` has open for this camera, if any. The index
  # says nothing about which lane wrote a row (D-E7), and a camera flipping from
  # tier 2 to tier 1 starts a recorder while the tracked event it had is still
  # being written — so the tracked lane's own live-event witness is asked, and
  # what it names is left alone.
  defp tracked_event_id(camera_id) do
    case Cairn.EventCheckpoint.get(camera_id) do
      {%Event{id: id}, _tracks} -> id
      _none -> nil
    end
  end

  defp end_stranded(state, row, extractor) do
    Logger.warning(
      "event #{row.id} (#{state.camera_id}): extractor still writing with no checkpoint " <>
        "to restore from — ending it partial"
    )

    # Rebuilt from the row rather than emptied: the extractor writes what it is
    # handed back over the row when it finalizes (`Cairn.Events.finalize/2`),
    # so an event with no labels would erase the ones the clip actually earned.
    labels = row.labels || %{}
    max_scores = Map.get(labels, "max_scores", %{})

    event = %Event{
      id: row.id,
      camera_id: row.camera_id,
      started_at: row.started_at,
      ended_at: now(),
      status: :partial,
      labels: Map.get(labels, "entries", []),
      max_scores: max_scores,
      # `create_active/2` writes no `max_score` column — only the close does —
      # so an event that never got that far has it only inside the labels map.
      max_score: row.max_score || best_score(max_scores),
      trigger: Map.get(labels, "trigger"),
      path: row.path
    }

    # `maybe_finalize/3`'s ordering, for its reason: the window is announced
    # closed before the clip is told to land, and the cast carries every box
    # already sent ahead of it.
    Event.broadcast(:event_ended, event)
    state.finalize_extractor.(extractor, event)
  end

  # `indexed_status/1`'s guards around the sweep's own read: an index that will
  # not answer costs the sweep, not the camera's lane, and the stranded clip is
  # then boot reconciliation's problem — where it was before this existed.
  defp active_rows(camera_id) do
    Events.active_for_camera(camera_id)
  rescue
    e in [DBConnection.ConnectionError, DBConnection.OwnershipError, Exqlite.Error] ->
      log_sweep_skipped(camera_id, Exception.message(e))
      []
  catch
    :exit, reason ->
      log_sweep_skipped(camera_id, inspect(reason))
      []
  end

  defp log_sweep_skipped(camera_id, reason) do
    Logger.warning(
      "camera #{camera_id}: could not consult the event index for stranded " <>
        "extractors (#{reason}); skipping the sweep"
    )
  end

  # Extractor gone: `Cairn.CameraTracker.end_orphan/2`'s semantics. The index
  # row, if one was written, stays `:active` on disk and boot reconciliation
  # marks it partial; what is decided here is only the broadcast. The extractor
  # may have got there first — its finalize cast can have been in the mailbox
  # when the process that sent it died — and re-announcing that event
  # `:partial` would both invert the artifact ordering and mislabel a clean
  # event, so the index, which the extractor wrote, decides.
  defp orphan(state, event) do
    PresenceCheckpoint.delete(state.camera_id)

    case indexed_status(event.id) do
      :finalized -> :ok
      _unfinished -> Event.broadcast(:event_ended, %{event | status: :partial, ended_at: now()})
    end

    state
  end

  defp finished_before_restore?(%{adopted_extractor?: true}, event),
    do: indexed_status(event.id) == :finalized

  defp finished_before_restore?(_state, _event), do: false

  # `Cairn.CameraTracker.indexed_status/1`, and for its reason: this can run
  # inside `init/1`, where an unreachable, locked or (in tests) unowned
  # database must not turn into a start failure for a camera whose stream is
  # fine. A storage failure degrades to "the index says nothing", and the
  # caller then announces the event `:partial` — recoverable, since
  # `event_ended` is at-least-once and consumers dedupe on the event id.
  defp indexed_status(event_id) do
    case Events.get(event_id) do
      %{status: status} -> status
      _no_row -> nil
    end
  rescue
    e in [DBConnection.ConnectionError, DBConnection.OwnershipError, Exqlite.Error] ->
      log_index_unavailable(event_id, Exception.message(e))
      nil
  catch
    # the connection pool or the repo process itself is gone
    :exit, reason ->
      log_index_unavailable(event_id, inspect(reason))
      nil
  end

  defp log_index_unavailable(event_id, reason) do
    Logger.warning(
      "event #{event_id}: could not consult the event index during restore " <>
        "(#{reason}); announcing it as partial"
    )
  end

  # The ledger read. `Cairn.PresenceLedger` holds every `{camera, label}` a
  # `presence_started` went out for and no `presence_cleared` has answered —
  # the aggregator's own present set, which survives this process. A qualifying
  # label in it that the checkpoint did not name is a started this process was
  # down for, and nothing will mention it again: a label the aggregator holds
  # as `:present` never confirms a second time before it has cleared.
  #
  # Read, never consumed: those rows are the aggregator's to clear (its
  # `init/1` emits the cleareds they owe), and taking them here would delete a
  # clear a client is still waiting on. The two restarts may be in flight
  # together, which needs no ordering — a cleared for a label adopted here
  # arrives as an ordinary transition and closes the event through the post
  # window, and one for a label not adopted falls out on membership. That is
  # also this read's worst case: an aggregator about to clear a label leaves an
  # event that opens and closes one post window later.
  defp adopt_announced(state) do
    case announced_seeds(state) do
      [] ->
        state

      seeds ->
        Logger.info(
          "camera #{state.camera_id}: #{length(seeds)} announced label(s) " <>
            "had no event after the restart — adopting"
        )

        # Dated now, both instants: the ledger's `first_seen_at` says when the
        # label was first SEEN, which can be far older than this restart, and a
        # clip that reaches no further back than the ring's pre-window must not
        # claim to have started there.
        admit(state, seeds, now(), now())
    end
  end

  defp announced_seeds(state) do
    for {label, _first_seen_at, score} <- PresenceLedger.leftovers(state.camera_id),
        not MapSet.member?(state.present_labels, label),
        earns_video?(state, label, score),
        do: {label, score}
  end

  defp announced_labels(state) do
    for {label, _first_seen_at, _score} <- PresenceLedger.leftovers(state.camera_id), do: label
  end

  # The same read with the scores kept — what a restore needs and a segment
  # boundary does not, since by then this process has watched the stay itself.
  defp announced_scores(state) do
    for {label, _first_seen_at, score} <- PresenceLedger.leftovers(state.camera_id),
        into: %{},
        do: {label, score}
  end

  # -- policy -----------------------------------------------------------------

  defp qualifies?(state, %PresenceEvent{label: label, score: score}),
    do: earns_video?(state, label, score)

  defp earns_video?(state, label, score) when is_number(score),
    do: Config.earns_video?(record_tier(state), label, score, transition_floors(state))

  # A `Cairn.PresenceEvent`'s score is nil-able, and so is a
  # `Cairn.PresenceLedger` row's, and a nil must never reach the comparison:
  # Elixir's term order answers `nil >= 0.5` with `true`, which would open an
  # event on a transition carrying no evidence at all. Only opening is refused
  # — a clear goes by membership and needs no score.
  defp earns_video?(_state, _label, _score), do: false

  defp qualifying_object?(state, object) do
    Cairn.Observation.detected?(object) and is_number(Map.get(object, :score)) and
      Config.earns_video?(record_tier(state), object.label, object.score, floors(state))
  end

  defp record_tier(%{policy: policy}), do: Map.get(policy, :record)

  # The one gate that must not trust the floors that rode in with the last
  # batch. The transition and the frames are cast by different processes, so a
  # confirm can arrive ahead of the batch that produced it — and after an
  # operator LOWERS the runtime `min_score`, the floors still in hand are the
  # ones from before the change. Refusing a score the aggregator has already
  # admitted loses the whole event, not one frame: the label is `:present` from
  # then on, and a present label never confirms again until it has cleared.
  #
  # Per-frame gating deliberately keeps the ride-along floors — those are the
  # ones their own frames were judged against.
  defp transition_floors(state), do: override_floors(state.camera_id) || floors(state)

  defp floors(%{floors: floors}) when is_map(floors), do: floors

  # Until the first buffer lands there are no floors to inherit, so judge with
  # what the sink would have: a runtime override REPLACES the camera's
  # thresholds as every label's default (`PresenceSink.effective_min_score/2`),
  # and the configured map answers when there is none.
  defp floors(%{camera_id: camera_id} = state),
    do: override_floors(camera_id) || configured_floors(state)

  defp override_floors(camera_id) do
    case CameraControl.get(camera_id) do
      %{min_score: override} when is_number(override) -> %{"default" => override}
      _no_override -> nil
    end
  end

  defp configured_floors(%{camera: %Config.Camera{min_score: min_score}})
       when is_map(min_score),
       do: min_score

  defp configured_floors(_state), do: %{}

  # The one runtime control on this path: an operator who switched recording
  # off gets no new events, exactly as at tier 2. An event already open is
  # unaffected — it is being written.
  defp recording_enabled?(state), do: CameraControl.get(state.camera_id).recording_enabled

  defp resolve_policy(state) do
    case state.resolve_policy.(state.camera_id) do
      {%Config.Camera{} = camera, policy} -> %{state | camera: camera, policy: policy}
      :error -> hold_policy(state)
    end
  end

  # The camera's own config, or `:error` when the config server cannot answer —
  # it is a `call`, and a lane must not die inside its own restart window.
  defp policy_from_config(camera_id) do
    camera =
      case Config.Server.camera(camera_id) do
        {:ok, camera} -> camera
        :error -> %Config.Camera{id: camera_id}
      end

    {camera, Config.policy(Config.Server.get(), camera)}
  catch
    :exit, _ -> :error
  end

  # Whatever was last resolved still answers; at init there is nothing to keep,
  # so the camera reads as a default one — an absent `record:` block, which
  # admits everything above the wire floor.
  defp hold_policy(%{policy: nil} = state) do
    camera = %Config.Camera{id: state.camera_id}
    %{state | camera: camera, policy: Config.policy(%Config{}, camera)}
  end

  defp hold_policy(state), do: state

  # -- helpers ----------------------------------------------------------------

  defp label_entry(label, score, t_ms) do
    %{
      t: Float.round(max(t_ms / 1000, 0.0), 1),
      label: label,
      score: score,
      # The tracked lane's identity column, empty by construction here.
      object_id: nil
    }
  end

  defp take_entries(entries, new), do: Enum.take(entries ++ new, @max_label_entries)

  defp merge_score(scores, label, score),
    do: Map.update(scores, label, score, &max(&1, score))

  defp best_score(max_scores), do: max_scores |> Map.values() |> Enum.max(fn -> nil end)

  # The frame's own instant, as unix milliseconds. `Cairn.Native.Observations`
  # judges the same field the same way: the engine answers `i64::MAX` for a
  # clock too far ahead to express, and that is not a time to date boxes by.
  defp frame_unix_ms(%{observed_at_ms: ms}) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, _at} -> ms
      {:error, _reason} -> now_unix_ms()
    end
  end

  defp frame_unix_ms(_frame), do: now_unix_ms()

  defp now_unix_ms, do: DateTime.to_unix(DateTime.utc_now(), :millisecond)

  defp default_monotonic_ms, do: System.monotonic_time(:millisecond)

  defp now, do: DateTime.utc_now()
end
