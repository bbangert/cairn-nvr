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
      overlay colours by label (`Cairn.TrackPath`). Two objects of one label
      in one frame therefore share a path.
    * **The post window is armed by a clear, not reset by evidence.** The
      tracked lane re-arms its post timer on every batch of evidence; here a
      label is *present* until the aggregator says otherwise, so the timer is
      scheduled when the last qualifying label clears and cancelled if one
      confirms again inside it. The max-event timer is the same unconditional
      cap it is there.

  The checkpoint is written to `Cairn.PresenceCheckpoint` and never to
  `Cairn.EventCheckpoint` — see that module for why the keyspaces must not
  meet. Reading it back on restart lands with the recovery phase; a restarted
  recorder today starts blank, and the row its predecessor left is inert
  rather than dangerous.
  """

  use GenServer, restart: :transient

  require Logger

  alias Cairn.{CameraControl, Config, Event, PresenceCheckpoint, PresenceEvent}

  @max_label_entries 5_000
  # `Cairn.CameraTracker`'s throttle and for its reason: the row is a deep ETS
  # copy of the whole event, it exists only so a replacement process can
  # re-attach to a live extractor, and a recovered event is written `:partial`
  # either way. The event's first and last writes are exempt.
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

  An open event outlives the retire — its clip is being written and its
  post/max timers are what close it — so this only latches, and the process
  stops when the event does. The aggregator's own retire has already flushed
  its labels, so the cleareds that close the event are on their way here.
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
      present_labels: MapSet.new(),
      checkpointed_at: nil,
      post_ref: nil,
      post_token: nil,
      max_ref: nil,
      max_token: nil,
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

    {:ok, resolve_policy(state)}
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
  def handle_cast(:retire, state), do: {:noreply, %{state | retiring?: true}}

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

  # ANY exit while the event is open ends it `:partial` — including `:normal`
  # and `:noproc`. `Cairn.CameraTracker` treats those two as a clean finish,
  # but its rule serves a restore path re-attaching to an extractor that may
  # have finalized already; the one monitor this module sets is on an
  # extractor it just started, so a clean-looking reason here is the extractor
  # dying before it did its work, and clearing silently would strand the
  # checkpoint row, the `:active` DB row and every `:event_ended` subscriber.
  # The genuinely clean post-finalize `:DOWN` never reaches this clause:
  # `maybe_finalize/3` cleared `extractor` first, so it falls to the
  # catch-all. When the recovery phase adds re-attach, CameraTracker's
  # indexed-status check comes with it.
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{extractor: pid} = state) do
    case state.event do
      %Event{} = event ->
        Logger.warning("event #{event.id}: extractor exited open (#{inspect(reason)})")
        PresenceCheckpoint.delete(state.camera_id)
        Event.broadcast(:event_ended, %{event | status: :partial, ended_at: now()})
        settle(clear_event(state))

      nil ->
        settle(clear_event(state))
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # A retire that arrived with an event open latched instead of stopping; this
  # is where it is paid, once the event that outranked it has closed.
  defp settle(%{retiring?: true, event: nil} = state), do: {:stop, :normal, state}
  defp settle(state), do: {:noreply, state}

  # -- transitions ------------------------------------------------------------

  defp started(state, presence) do
    state =
      %{state | present_labels: MapSet.put(state.present_labels, presence.label)}
      |> cancel_post()

    cond do
      state.event != nil -> merge_label(state, presence)
      recording_enabled?(state) -> start_event(state, presence)
      true -> state
    end
  end

  # The checkpoint is written on the edge and past the throttle, the rule the
  # event's own first and last writes follow: what a clear changes is which
  # labels the row still names and whether the close clock is running, which is
  # exactly what a restore has to be told and what a throttled write can be a
  # second late with.
  defp cleared(state, label) do
    present = MapSet.delete(state.present_labels, label)
    state = %{state | present_labels: present}

    cond do
      state.event == nil -> state
      # The last qualifying label left: the only thing that starts the close
      # clock, so an event whose labels never clear runs to `max_event`.
      MapSet.size(present) == 0 -> state |> write_checkpoint() |> arm_post()
      true -> write_checkpoint(state)
    end
  end

  defp start_event(state, presence) do
    # `first_seen_at`, not the confirm's `at`: presence is confirmed on the
    # second sighting, and the event began at the first. The pre-window covers
    # both, and every box's `t_ms` is measured from this instant.
    started_at = presence.first_seen_at

    event = %Event{
      id: Ecto.UUID.generate(),
      camera_id: state.camera_id,
      started_at: started_at,
      status: :active,
      labels: [label_entry(presence.label, presence.score, 0)],
      max_scores: %{presence.label => presence.score},
      max_score: presence.score,
      # No box at a confirm — the aggregator carries none. The first frame
      # that arrives while this is open sets it (`best_trigger/3`), and an
      # event that sees none falls back to `Cairn.Snapshot`'s boxless path.
      trigger: nil
    }

    case state.start_extractor.(state.camera, event) do
      {:ok, pid} ->
        Process.monitor(pid)
        PresenceCheckpoint.put(state.camera_id, event, MapSet.to_list(state.present_labels))
        Event.broadcast(:event_started, event)
        {max_ref, max_token} = schedule(:max_event, event.id, state.policy.max)

        replay_pending(%{
          state
          | event: event,
            started_unix_ms: DateTime.to_unix(started_at, :millisecond),
            checkpointed_at: state.monotonic_ms.(),
            extractor: pid,
            max_ref: max_ref,
            max_token: max_token
        })

      {:error, reason} ->
        Logger.error("camera #{state.camera_id}: could not start extractor: #{inspect(reason)}")
        state
    end
  end

  # A second label confirming while an event is open extends it rather than
  # opening a second one (one event per camera, labels merged). The frames do
  # this too, per detection; doing it here as well puts the label on the row at
  # the moment the lane admitted it rather than at whatever later frame the
  # motion gate lets through — a still scene delivers none at all.
  defp merge_label(state, presence) do
    event = state.event
    new_label? = not Map.has_key?(event.max_scores, presence.label)
    t_ms = DateTime.diff(presence.at, event.started_at, :millisecond)
    max_scores = merge_score(event.max_scores, presence.label, presence.score)

    event = %{
      event
      | labels: take_entries(event.labels, [label_entry(presence.label, presence.score, t_ms)]),
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

    forward_boxes(state, t_ms, objects)
    fold(state, Enum.filter(objects, &qualifying_object?(state, &1)), t_ms)
  end

  # The dense half of the playback overlay, in the compact shape
  # `Cairn.TrackPath` reads. Deliberately unfiltered — no floor, no `record:`
  # tier — for the tracked lane's reason: what earns video is a different
  # question from what is drawn over video already recorded.
  #
  # Both elements of the entry's identity pair are the label (D-E5b): with no
  # tracker there is nothing else to key a path by. `Cairn.TrackPath` keeps one
  # sample per identity per instant, and the highest-scoring box of a label is
  # sorted to the front so it is the one that survives two people in one frame.
  #
  # **Ordering dependency**, `Cairn.CameraTracker.forward_boxes/2`'s: this cast
  # and the finalize cast in `maybe_finalize/3` share a sender and a receiver,
  # so every box sent before finalize is in the extractor's mailbox before it.
  # A `call`, or a finalize routed through another process, silently truncates
  # the sidecar's tail.
  defp forward_boxes(%{extractor: pid}, t_ms, objects) when is_pid(pid) do
    boxes =
      objects
      |> Enum.filter(&boxed?/1)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.map(&{&1.label, &1.label, &1.bbox, false})

    if boxes != [] do
      GenServer.cast(pid, {:track_boxes, %{t_ms: t_ms, boxes: boxes}})
    end
  end

  defp forward_boxes(_state, _t_ms, _objects), do: :ok

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

    state = checkpoint(%{state | event: event})

    # Only a label the event had not seen: a frame rate's worth of
    # `:event_updated` per second would be a firehose, and what a subscriber
    # cannot learn any other way is that the event grew a label.
    if map_size(max_scores) > map_size(known) do
      Event.broadcast(:event_updated, event)
    end

    state
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
    clear_event(state)
  end

  defp maybe_finalize(state, _event_id, _cause), do: state

  defp clear_event(state) do
    if state.post_ref, do: Process.cancel_timer(state.post_ref)
    if state.max_ref, do: Process.cancel_timer(state.max_ref)

    %{
      state
      | event: nil,
        started_unix_ms: nil,
        extractor: nil,
        checkpointed_at: nil,
        post_ref: nil,
        post_token: nil,
        max_ref: nil,
        max_token: nil
    }
  end

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
    PresenceCheckpoint.put(state.camera_id, state.event, MapSet.to_list(state.present_labels))
    %{state | checkpointed_at: state.monotonic_ms.()}
  end

  # -- policy -----------------------------------------------------------------

  defp qualifies?(state, %PresenceEvent{label: label, score: score}) when is_number(score),
    do: Config.earns_video?(record_tier(state), label, score, floors(state))

  # `Cairn.PresenceEvent`'s score is nil-able, and a nil must never reach the
  # comparison: Elixir's term order answers `nil >= 0.5` with `true`, which
  # would open an event on a transition carrying no evidence at all. Only
  # opening is refused — a clear goes by membership and needs no score.
  defp qualifies?(_state, _presence), do: false

  defp qualifying_object?(state, object) do
    Cairn.Observation.detected?(object) and is_number(Map.get(object, :score)) and
      Config.earns_video?(record_tier(state), object.label, object.score, floors(state))
  end

  defp record_tier(%{policy: policy}), do: Map.get(policy, :record)

  defp floors(%{floors: floors}) when is_map(floors), do: floors

  # Until the first buffer lands, judge with what the sink would have: a
  # runtime override REPLACES the camera's thresholds as every label's default
  # (`PresenceSink.effective_min_score/2`). A confirm can reach a recorder
  # whose floors are still nil — restarted mid-window, transition cast racing
  # the frames cast — and the configured map alone would refuse a score the
  # sink admitted under a lowered override, silently recording nothing.
  defp floors(%{camera_id: camera_id} = state) do
    case CameraControl.get(camera_id) do
      %{min_score: override} when is_number(override) -> %{"default" => override}
      _control -> configured_floors(state)
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
