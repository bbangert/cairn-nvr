defmodule Cairn.DetectionAggregator do
  @moduledoc """
  Owns the event lifecycle, one active event per camera.

  Receives decoded `Cairn.Observation`s from `Cairn.PluginPort` /
  `Cairn.PluginGroupPort`, filters by per-label `min_score`, assigns stable
  object identities (`Cairn.Tracker`, ULID strings), and:

    * no active event + evidence -> starts a `Cairn.EventExtractor` and
      broadcasts `{:event_started, event}` on `"events"`
    * evidence during an event -> accumulates time-indexed labels, resets
      the post-window timer, broadcasts `{:event_updated, event}`
    * `post_window` seconds of quiet -> finalizes; `max_event` seconds ->
      finalizes and lets the next piece of evidence open a fresh event

  Not every detection is evidence (`evidence?/2`, the one gate both of the
  first two bullets pass through): a predicted ("tracked") object is refused,
  and so is one whose track the tracker has judged **stationary**. A parked car
  therefore stops resetting the post-window, the event closes on schedule and
  stays closed — nothing reopens it while the car sits there — and the car is
  evidence again the moment it moves.

  `{:event_ended, event}` means the detection window closed and nothing more:
  it is broadcast before the extractor is even told to finalize, so the clip
  is still being written and the snapshot does not exist. The media itself is
  announced by `Cairn.EventArtifact`.

  Event times come from the observation, not from the clock: `started_at`,
  `labels[].t` and `trigger.t` derive from `observation.observed_at`, which a
  v1 plugin captured next to the frame. Wall-clock time is still what closes
  an event — `ended_at`, the post-window and max-event timers — because
  quiet produces no observations to measure quiet with.

  Track lifecycle is published on the same `"events"` topic as
  `%Cairn.Track{}` summaries: `track_started` and `track_ended` always,
  `track_updated` only when the track's best score improves or a second of
  wall clock has passed since its last update — a 5 fps stream with a dozen
  objects must not become a firehose of identical frames. A stationary
  transition is published immediately whatever the throttle says: the flag
  decides whether the object is evidence, so a consumer must not learn of the
  flip up to a second after this module has already acted on it.

  The same lifecycle feeds the track index through `Cairn.TrackRecorder`:
  `:appeared` and the stationary flips are buffered as timeline moments, and a
  finished track is handed over as a row. Everything sent there is a cast —
  this process never touches `Cairn.Repo` on the detection path. A track live
  during an open event is recorded unconditionally with that event's id; only a
  track no event was open for is gated on the camera's `track:` tier (see
  `record_final/3`). Recording being disabled at runtime does not enter into
  it: rows without video are the point of the two tiers.

  Subscribes to `Cairn.StreamEpochs`: a new epoch for a camera ends every
  live track (`:stream_reset`) and starts a fresh tracker, so no identity is
  ever inherited across an outage. Turning detection off at runtime ends them
  too (`:detection_disabled`) — nothing would advance them while it is off.

  Active events are checkpointed to `Cairn.EventCheckpoint` (ETS owned
  elsewhere) together with the tracks live at that moment: on restart the
  aggregator re-attaches to live extractors, finalizes orphans and ends every
  restored track (`:host_restart`). Writes are throttled to one a second per
  camera apart from the event's first and last.
  """

  use GenServer

  require Logger

  alias Cairn.{CameraControl, Config, Event, EventCheckpoint, Events, Observation, StreamEpochs}
  alias Cairn.{Track, Tracker, TrackRecorder}

  @max_label_entries 5_000
  # Wall clock, deliberately: it throttles what a subscriber receives, which
  # has nothing to do with the stream's own clock.
  @update_throttle_ms 1_000
  # The checkpoint row is a deep ETS copy of the whole `%Event{}` (labels grow
  # to @max_label_entries) plus a freshly built, sorted track list, and it was
  # rewritten on every observation batch. It exists only so a crashed
  # aggregator can re-attach to live extractors and emit finals, and a
  # recovered event is written `:partial` either way — so losing the last
  # second of labels costs nothing that the recovery does not already cost.
  # The two transitions that *do* matter for restore are exempt: the first
  # write at event start, and the delete at event end.
  @checkpoint_throttle_ms 1_000

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Called by the plugin ports with a decoded, config-tagged observation.

  `policy` is `Cairn.Config.policy/2` for the camera: the event windows, the
  tracking bounds and the host-side `track:` / `record:` tiers, resolved at
  the port so this per-frame path never calls the config server.
  """
  @spec detections(GenServer.server(), Cairn.Config.Camera.t(), map(), Observation.t()) :: :ok
  def detections(server \\ __MODULE__, camera, policy, %Observation{} = observation) do
    GenServer.cast(server, {:detections, camera, policy, observation})
  end

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    StreamEpochs.subscribe()

    state = %{
      cameras: %{},
      # last announced epoch per camera, kept whether or not that camera has
      # tracker state yet: the first epoch of a camera's life is minted at
      # ffmpeg spawn, long before any detection creates `cameras[camera_id]`.
      epochs: %{},
      start_extractor: Keyword.get(opts, :start_extractor, &Cairn.EventExtractor.start/2),
      finalize_extractor:
        Keyword.get(opts, :finalize_extractor, &Cairn.EventExtractor.finalize/2),
      # The track index's batch writer, injectable for the same reason as the
      # two above. Everything sent to it is a cast, so this path never waits on
      # the database — see `Cairn.TrackRecorder`.
      recorder: Keyword.get(opts, :recorder, TrackRecorder),
      # injectable so the update throttle can be tested without sleeping
      monotonic_ms: Keyword.get(opts, :monotonic_ms, &default_monotonic_ms/0)
    }

    {:ok, restore_from_checkpoint(state)}
  end

  @impl true
  def handle_cast({:detections, camera, policy, observation}, state) do
    control = CameraControl.get(camera.id)
    observation = with_observed_at(observation)

    cond do
      not control.detection_enabled ->
        # detection disabled at runtime: drop the batch, and retire whatever
        # was live — nothing will advance those tracks while detection is off,
        # so leaving them "live" would strand every consumer's entities and
        # keep their throttle state resident. An in-flight event is left to
        # finalize naturally on its post-window timer.
        {:noreply, end_tracks_disabled(state, camera.id)}

      stale?(state, camera.id, observation) ->
        {:noreply, state}

      true ->
        {:noreply, process_detections(state, camera, policy, observation, control)}
    end
  end

  # Invariant: every observation leaving a port carries a `%DateTime{}` — the
  # codec parses one for v1 and the port stamps arrival for v0 — and every
  # time in an event derives from it. This is a *singleton* holding every
  # camera's in-flight event state, so a `nil` slipping through must not be a
  # `FunctionClauseError` in `DateTime.diff/3` here.
  defp with_observed_at(%Observation{observed_at: at} = observation)
       when is_struct(at, DateTime),
       do: observation

  defp with_observed_at(observation), do: %{observation | observed_at: now()}

  # Belt and braces: the ports already refuse observations from an epoch that
  # is no longer current, and this closes the window where a port's line and
  # the epoch broadcast cross. Compared against the same `current_epoch` the
  # epoch broadcast maintains — including for a camera with no tracker state
  # yet, whose announced epoch is remembered in `epochs`.
  #
  # An observation with no epoch (v0 before the first ffmpeg spawn) is
  # accepted, as is one for a camera whose epoch is not known here yet: that
  # first observation's epoch is adopted in `process_detections/5`.
  defp stale?(_state, _camera_id, %Observation{epoch: nil}), do: false

  defp stale?(state, camera_id, %Observation{epoch: epoch}) do
    case current_epoch(state, camera_id) do
      nil ->
        false

      ^epoch ->
        false

      _other ->
        # Rare by construction, so it is counted rather than logged per line:
        # a steady rate here means a port is forwarding across a boundary.
        :telemetry.execute([:cairn, :aggregator, :stale_observation], %{count: 1}, %{
          camera_id: camera_id
        })

        Logger.debug("camera #{camera_id}: dropped observation from stale epoch #{epoch}")
        true
    end
  end

  # The camera's own state is authoritative once it exists; before that, the
  # last announced epoch is all there is.
  defp current_epoch(state, camera_id) do
    case state.cameras do
      %{^camera_id => cam} -> cam.current_epoch
      _absent -> state.epochs[camera_id]
    end
  end

  defp process_detections(state, camera, policy, observation, control) do
    cam = cam_state(state, camera.id)

    context =
      Tracker.context(observation, camera.id, tracking_policy(policy), state.monotonic_ms.())

    {tracker, tagged, track_events} = Tracker.track(cam.tracker, observation.objects, context)

    cam =
      %{
        cam
        | tracker: tracker,
          current_epoch: cam.current_epoch || observation.epoch,
          # Cached for the track rows, and set before the events of this batch
          # are published so a track ending in it is gated on this batch's
          # policy. The ended-track paths that need them — `apply_epoch/4`,
          # `end_tracks_disabled/2`, checkpoint restore — are handed neither a
          # camera nor a policy, and reaching for the config server there would
          # put a call on a path an epoch broadcast drives.
          policy: policy,
          camera: camera
      }
      |> publish_tracks(track_events, state)

    # A predicted ("tracked") object, a track the plugin keeps predicting long
    # after anything last detected it, and a track that has held still past the
    # camera's `stationary_after_ms` are all not evidence: they keep the
    # tracker warm but can neither open an event nor hold one open.
    min_score = effective_min_score(camera, control)
    passing = Enum.filter(tagged, &evidence?(&1, min_score))

    cam =
      cond do
        passing == [] -> cam
        # recording disabled: evaluate detections but don't open a new event
        cam.event == nil and not control.recording_enabled -> cam
        cam.event == nil -> start_event(state, camera, policy, observation, passing, cam)
        true -> update_event(cam, policy, observation, passing, state)
      end

    put_cam(state, camera.id, cam)
  end

  # The single gate: the objects this accepts are `passing`, which is what both
  # `start_event/6` and `update_event/5` are handed, so what is refused here
  # can neither open an event nor hold one open. That pairing is the whole
  # point of the stationary rule — a parked car keeps producing detections, and
  # refusing them is what lets the post-window run out instead of being reset
  # by every frame of a car that is going nowhere.
  #
  # `object.stationary` is read directly rather than defaulted: every object
  # this is called with came out of `Tracker.track/3`, which tags `object_id`,
  # `stale_predicted` and `stationary` onto every object it returns.
  #
  # `stale_predicted` is not checked here and must not be: the tracker sets it
  # from the last *detection*, so an object that is detected in this batch
  # always carries `false`. The staleness rule bites through `detected?/1`
  # instead — a track the plugin keeps predicting arrives as `"tracked"`.
  defp evidence?(object, min_score) do
    Observation.detected?(object) and not object.stationary and
      passes_min_score?(object, min_score)
  end

  # Defensive on a public, @spec'd entry point (`detections/4`) that any caller
  # can hand a bare map: the tracker's bounds must not silently become nil.
  defp tracking_policy(policy) do
    %{
      max_unseen_ms: Map.get(policy, :max_unseen_ms) || Config.default_max_unseen_ms(),
      max_live_tracks: Map.get(policy, :max_live_tracks) || Config.default_max_live_tracks(),
      stationary_after_ms:
        Map.get(policy, :stationary_after_ms) || Config.default_stationary_after_ms()
    }
  end

  # `keep_ended: true`, unlike the epoch cuts below: the epoch is unchanged
  # across a detection toggle, so the plugin ids already declared ended must
  # stay known — reusing one after re-enabling is the same contract violation
  # it was before.
  defp end_tracks_disabled(state, camera_id) do
    with %{^camera_id => cam} <- state.cameras,
         {tracker, [_ | _] = ended} <-
           Tracker.end_all(cam.tracker, :detection_disabled, keep_ended: true) do
      put_cam(state, camera_id, publish_tracks(%{cam | tracker: tracker}, ended, state))
    else
      # no tracker state, or nothing live: the second disabled batch onwards is
      # a no-op, and the tracker is left alone so its ended-id memory survives.
      _ -> state
    end
  end

  # A runtime min_score override replaces the camera's configured thresholds
  # (applied as the default for every label); nil means "use config".
  defp effective_min_score(camera, %{min_score: nil}), do: camera.min_score
  defp effective_min_score(_camera, %{min_score: override}), do: %{"default" => override}

  @impl true
  def handle_info({:post_window, camera_id, event_id, token}, state) do
    # the token guards against a stale timer message that was already in
    # the mailbox when a detection cancelled + rescheduled the window
    if token == get_in(state.cameras, [camera_id, :post_token]) do
      {:noreply, maybe_finalize(state, camera_id, event_id, :post_window)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:max_event, camera_id, event_id, token}, state) do
    if token == get_in(state.cameras, [camera_id, :max_token]) do
      {:noreply, maybe_finalize(state, camera_id, event_id, :max_event)}
    else
      {:noreply, state}
    end
  end

  # A new epoch is a new continuous decode: the camera may have moved during
  # the outage, so no track may span the boundary — otherwise a box that
  # happens to overlap the last one inherits its identity. Every live track is
  # ended (`:stream_reset`) with a final summary before the fresh tracker takes
  # over. An in-flight event keeps running and finalizes on its own timers.
  #
  # Detection casts already in flight when this arrives are processed *after*
  # the reset: they come from the plugin ports, not from `Cairn.StreamEpochs`,
  # and the BEAM only orders messages per sender pair, so a batch from before
  # the boundary would otherwise seed the fresh tracker. The epoch now travels
  # with the batch — tagged at the producer, compared in `stale?/3` against the
  # `current_epoch` stored here — so such a batch is dropped instead.
  # An epoch older than the one already held is ignored (see
  # `Cairn.ULID.superseded?/2`): applying it would roll `current_epoch` back
  # to a stream nothing decodes under, and `stale?/3` would then drop every
  # observation the ports still forward — a silent, sustained outage for that
  # camera until its next mint.
  def handle_info({:stream_epoch, camera_id, epoch, reason}, state) do
    if Cairn.ULID.superseded?(current_epoch(state, camera_id), epoch) do
      {:noreply, state}
    else
      {:noreply, apply_epoch(state, camera_id, epoch, reason)}
    end
  end

  # `:noproc` is a clean finish, not a crash. `restore_from_checkpoint/1` can
  # monitor a pid the registry still lists but whose process is already gone
  # (unregistration rides the async DOWN the partition sends itself), and
  # `Process.monitor/1` on a corpse answers `:noproc` immediately. Treating it
  # as a crash logs a cleanly finalised event as crashed and re-announces it as
  # `:partial` in the event index.
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Enum.find(state.cameras, fn {_id, cam} -> cam.extractor == pid end) do
      {camera_id, %{event: %Event{} = event} = cam} when reason not in [:normal, :noproc] ->
        Logger.warning("event #{event.id}: extractor crashed (#{inspect(reason)})")
        EventCheckpoint.delete(camera_id)
        Event.broadcast(:event_ended, %{event | status: :partial, ended_at: now()})
        {:noreply, put_cam(state, camera_id, clear_event(cam))}

      {camera_id, cam} ->
        {:noreply, put_cam(state, camera_id, clear_event(cam))}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # `:camera_stopped` names the end of a stream, not the start of one: nothing
  # will ever decode under that epoch. It ends the live tracks (the stream they
  # belong to is over) but must never become `current_epoch` — the stop and the
  # start of one camera are announced by different processes, and on the
  # degraded caller-side broadcast path they have no ordering relation, so a
  # stop epoch minted after a live `:started` could otherwise be adopted as
  # current and `stale?/3` would then drop every observation of a *healthy*
  # camera until its next ffmpeg respawn — which is not coming.
  defp apply_epoch(state, camera_id, _epoch, :camera_stopped) do
    state = remember_epoch(state, camera_id, nil, :camera_stopped)

    case state.cameras do
      %{^camera_id => cam} ->
        {tracker, ended} = Tracker.end_all(cam.tracker, :stream_reset)
        put_cam(state, camera_id, publish_tracks(%{cam | tracker: tracker}, ended, state))

      _ ->
        state
    end
  end

  defp apply_epoch(state, camera_id, epoch, reason) do
    state = remember_epoch(state, camera_id, epoch, reason)

    case state.cameras do
      %{^camera_id => %{current_epoch: ^epoch}} ->
        # One mint can be announced twice by design: `Cairn.StreamEpochs`
        # broadcasts from the caller when its server is unreachable, and a
        # call that exited with :timeout may still be served afterwards. The
        # epoch is the same either way, so a repeat means no boundary was
        # crossed — ending every live track again would cut them mid-stream.
        # The repeat is caught even when the first announcement arrived before
        # this camera had any tracker state: `epochs` remembered it, and the
        # state created by the first detection starts out carrying it.
        state

      %{^camera_id => cam} ->
        {tracker, ended} = Tracker.end_all(cam.tracker, :stream_reset)

        cam =
          %{cam | tracker: tracker, current_epoch: epoch}
          |> publish_tracks(ended, state)

        put_cam(state, camera_id, cam)

      _ ->
        # no tracks to end. Allocating full camera state here would retain a
        # tracker for every camera that never emits detections, deleted ones
        # included; the epoch alone (one string) is cheap enough to keep.
        state
    end
  end

  # -- track lifecycle --------------------------------------------------------

  # `track_started`, `track_ended` and the stationary transitions always go
  # out: a subscriber that only ever sees the final summary still learns what
  # the track was, and the flag this module gates evidence on must not arrive
  # late. Plain updates are throttled per track — best-score improvement or a
  # second of wall clock.
  defp publish_tracks(cam, events, state) do
    Enum.reduce(events, cam, fn
      {:started, track}, cam ->
        Track.broadcast(:track_started, track)

        # The first moment on the track's timeline, and the only source of the
        # row's `entry_bbox`. Its time is the track's own `started_at`.
        TrackRecorder.record_moment(
          state.recorder,
          track.object_id,
          track.started_at,
          :appeared,
          track.bbox
        )

        note_update(cam, track, state)

      {:updated, track}, cam ->
        maybe_publish_update(cam, track, state)

      {:ended, track}, cam ->
        Track.broadcast(:track_ended, track)
        record_final(cam, track, state)
        %{cam | track_updates: Map.delete(cam.track_updates, track.object_id)}

      # Broadcast as a `track_updated` — the transition carries no fields of
      # its own, it is the `%Track{}` the flip is about — and noted, the same
      # throttle bypass `:started` gets.
      #
      # The tracker emits the paired `{:updated, track}` immediately before
      # this one carrying the *same* summary, so when the throttle happens to
      # let that one through a consumer sees one identical frame twice: a
      # repeat of a state snapshot, not a second transition. Running
      # `note_update` for both costs nothing — it overwrites one entry with the
      # same track's `best_score` at the same instant — and what it buys is
      # that the *next* `:updated` is throttled from the flip rather than from
      # whatever went out before it.
      #
      # The moment recorded for it is timed by `last_seen_at`, the summary's
      # own observation time, never the wall clock of this call: a
      # `Cairn.Tracks.TrackEvent` is read back against the clip's timeline, and
      # the flip happened when the media said it did.
      {kind, track}, cam when kind in [:became_stationary, :started_moving] ->
        Track.broadcast(:track_updated, track)

        TrackRecorder.record_moment(
          state.recorder,
          track.object_id,
          track.last_seen_at,
          kind,
          track.bbox
        )

        note_update(cam, track, state)
    end)
  end

  # Whether a finished track earns a row, and with which event.
  #
  # **An open event records the track unconditionally.** Every track live
  # during a clip is then queryable from that clip by construction, which is
  # the audit invariant the table exists for: without it a camera whose
  # `record:` block admits a label its `track:` block excludes would produce
  # clips whose contents cannot be enumerated — a cat that triggers a clip
  # through an absent `record:` block would have no row while the video of it
  # sits on disk.
  #
  # The `track:` tier gates only the tracks no event was open for — the audit
  # trail of what the system saw and did not record, where the tier is the
  # knob for how much of it to keep. (User decision, 2026-07-31, deviating
  # from the phase plan's unconditional gate.)
  #
  # Every end reason goes through the same rule. `:evicted`, `:stream_reset`,
  # `:detection_disabled` and `:host_restart` are the reasons a reader is most
  # likely to be investigating, and a row costs nothing.
  #
  # "Open" means open when the track ended: `publish_tracks/3` runs on the cam
  # state as it was before this batch, so a track that expires in the same
  # observation whose detections open a brand-new event is tier-gated, not
  # linked to that event. That is the right answer, not an artefact of the
  # ordering — a track expiring in this batch was by definition not detected in
  # it, so it contributed no evidence to the event those detections opened, and
  # the event it did belong to (if any) had already closed.
  defp record_final(%{event: %Event{id: event_id}}, track, state) do
    TrackRecorder.record_final(state.recorder, track, event_id)
  end

  defp record_final(cam, track, state) do
    # Belt and braces on the cached pair: every path that can produce a live
    # track today has been through `process_detections/5`, which caches both —
    # a tracker only exists on a camera that has had a detection. An end path
    # that ever skips it must not silently exclude the track, so an absent
    # policy is read as an absent `track:` block, i.e. the label's wire floor
    # off a default camera.
    camera = cam.camera || %Config.Camera{id: track.camera_id}
    tier = cam.policy && Map.get(cam.policy, :track)

    case Config.tier_threshold(tier, track.label, camera.min_score) do
      :excluded ->
        TrackRecorder.discard(state.recorder, track.object_id)

      threshold when is_number(threshold) ->
        if track.best_score >= threshold do
          TrackRecorder.record_final(state.recorder, track, nil)
        else
          TrackRecorder.discard(state.recorder, track.object_id)
        end
    end
  end

  defp maybe_publish_update(cam, track, state) do
    case Map.get(cam.track_updates, track.object_id) do
      nil ->
        Track.broadcast(:track_updated, track)
        note_update(cam, track, state)

      last ->
        if track.best_score > last.best_score or
             state.monotonic_ms.() - last.at >= @update_throttle_ms do
          Track.broadcast(:track_updated, track)
          note_update(cam, track, state)
        else
          cam
        end
    end
  end

  defp note_update(cam, track, state) do
    entry = %{at: state.monotonic_ms.(), best_score: track.best_score}
    %{cam | track_updates: Map.put(cam.track_updates, track.object_id, entry)}
  end

  defp default_monotonic_ms, do: System.monotonic_time(:millisecond)

  # -- lifecycle --------------------------------------------------------------

  defp start_event(state, camera, policy, observation, dets, cam) do
    observed_at = observation.observed_at

    event = %Event{
      id: Ecto.UUID.generate(),
      camera_id: camera.id,
      started_at: observed_at,
      status: :active,
      labels: label_entries([], dets, observed_at, observed_at),
      max_scores: max_scores(%{}, dets),
      trigger: best_trigger(nil, dets, 0.0)
    }

    event = %{event | max_score: event.max_scores |> Map.values() |> Enum.max(fn -> nil end)}

    case state.start_extractor.(camera, event) do
      {:ok, pid} ->
        Process.monitor(pid)
        EventCheckpoint.put(camera.id, event, Tracker.live_tracks(cam.tracker))
        Event.broadcast(:event_started, event)

        {post_ref, post_token} = schedule(:post_window, camera.id, event.id, policy.post)
        {max_ref, max_token} = schedule(:max_event, camera.id, event.id, policy.max)

        %{
          cam
          | event: event,
            checkpointed_at: state.monotonic_ms.(),
            extractor: pid,
            post_ref: post_ref,
            post_token: post_token,
            max_ref: max_ref,
            max_token: max_token
        }

      {:error, reason} ->
        Logger.error("camera #{camera.id}: could not start extractor: #{inspect(reason)}")
        cam
    end
  end

  defp update_event(%{event: event} = cam, policy, observation, dets, state) do
    max_scores = max_scores(event.max_scores, dets)
    observed_at = observation.observed_at

    event = %{
      event
      | labels: label_entries(event.labels, dets, event.started_at, observed_at),
        max_scores: max_scores,
        max_score: max_scores |> Map.values() |> Enum.max(fn -> nil end),
        trigger:
          best_trigger(
            event.trigger,
            dets,
            DateTime.diff(observed_at, event.started_at, :millisecond) / 1000
          )
    }

    if cam.post_ref, do: Process.cancel_timer(cam.post_ref)
    cam = checkpoint(%{cam | event: event}, state)
    Event.broadcast(:event_updated, event)

    {post_ref, post_token} = schedule(:post_window, event.camera_id, event.id, policy.post)
    %{cam | post_ref: post_ref, post_token: post_token}
  end

  defp checkpoint(%{event: event} = cam, state) do
    now = state.monotonic_ms.()

    if cam.checkpointed_at == nil or now - cam.checkpointed_at >= @checkpoint_throttle_ms do
      EventCheckpoint.put(event.camera_id, event, Tracker.live_tracks(cam.tracker))
      %{cam | checkpointed_at: now}
    else
      cam
    end
  end

  defp maybe_finalize(state, camera_id, event_id, cause) do
    case state.cameras[camera_id] do
      %{event: %Event{id: ^event_id} = event} = cam ->
        Logger.info("event #{event.id} (#{camera_id}): finalizing (#{cause})")
        event = %{event | ended_at: now(), status: :finalized}
        # Ended first, then the extractor is told: the extractor's
        # `:event_clip_ready` can only follow the cast, so a subscriber is
        # guaranteed to learn the window closed before it learns the clip
        # landed. The reverse order lets a fast finalize overtake it.
        Event.broadcast(:event_ended, event)
        state.finalize_extractor.(cam.extractor, event)
        EventCheckpoint.delete(camera_id)
        put_cam(state, camera_id, clear_event(cam))

      _ ->
        state
    end
  end

  # -- restore ----------------------------------------------------------------

  # Every restored track is dead: the tracker that owned it died with the
  # aggregator and a fresh one has no state to continue it. They are ended
  # (`:host_restart`) with their last known summary. New objects can never be
  # confused with them — a ULID is minted once, so a restored event's label
  # ids are never handed out again.
  defp restore_from_checkpoint(state) do
    Enum.reduce(EventCheckpoint.all(), state, fn {camera_id, event, tracks}, state ->
      Enum.each(tracks, fn track ->
        final = %{track | end_reason: :host_restart}
        Track.broadcast(:track_ended, final)
        # Unconditionally, and with the checkpointed event's id: a checkpoint
        # row exists only while an event is open, so every track restored here
        # was live during that clip — the same rule `record_final/3` applies to
        # an open event. No tier is consulted because none is known here; the
        # camera's policy lives in the config server, and this runs inside
        # `init/1`.
        TrackRecorder.record_final(state.recorder, final, event.id)
      end)

      case Cairn.Registry.whereis(camera_id, {:extractor, event.id}) do
        nil ->
          end_orphan(camera_id, event)
          state

        # Alive but possibly mid-finalize: the `{:DOWN, _, _, _, :normal}` that
        # follows clears the camera silently, which is only correct because the
        # aggregator broadcasts `:event_ended` *before* the finalize cast (see
        # `maybe_finalize/4`) — the pre-crash aggregator already announced it.
        # Possibly not even alive: the entry may be a corpse the registry has
        # not reaped yet, in which case the monitor answers `:noproc`, which
        # `handle_info/2` treats as the same clean finish.
        pid ->
          Process.monitor(pid)
          cam = %{new_cam() | event: event, extractor: pid}
          # the camera's own policy is unknown here; use the global defaults
          policy = Config.policy(config(), %Config.Camera{id: camera_id})
          {post_ref, post_token} = schedule(:post_window, camera_id, event.id, policy.post)
          {max_ref, max_token} = schedule(:max_event, camera_id, event.id, policy.max)

          cam = %{
            cam
            | post_ref: post_ref,
              post_token: post_token,
              max_ref: max_ref,
              max_token: max_token
          }

          put_cam(state, camera_id, cam)
      end
    end)
  end

  # Extractor gone: the index row (if any) stays active on disk and boot-time
  # reconciliation will mark it partial.
  #
  # Unless the extractor got there first: the crash window includes "the
  # finalize cast was already in its mailbox", in which case it finalized the
  # row and announced `:event_clip_ready` before exiting `:normal`.
  # Re-announcing that event as `:partial` here would both invert the artifact
  # ordering and mislabel a clean event — so the index, which the extractor
  # wrote, decides.
  defp end_orphan(camera_id, event) do
    EventCheckpoint.delete(camera_id)

    case indexed_status(event.id) do
      :finalized -> :ok
      _ -> Event.broadcast(:event_ended, %{event | status: :partial, ended_at: now()})
    end
  end

  # This runs inside `init/1` — the only Repo call the aggregator makes before
  # it is alive — and the aggregator is a singleton handling detections for
  # every camera. An unreachable, locked or (in tests) unowned database must
  # not turn into a supervisor restart loop on that one process, so a storage
  # failure degrades to "index says nothing" and the caller announces the
  # event `:partial`. Mislabelling a finalized event that way is recoverable:
  # `event_ended` is at-least-once and consumers dedupe on the event id (see
  # docs/ha-api.md). Only the storage layer's own failures are caught — a bug
  # in here still raises.
  defp indexed_status(event_id) do
    case Events.get(event_id) do
      %{status: status} -> status
      _ -> nil
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

  defp config do
    Config.Server.get()
  rescue
    _ -> %Config{}
  catch
    :exit, _ -> %Config{}
  end

  # -- helpers ----------------------------------------------------------------

  defp passes_min_score?(det, min_score) do
    threshold = Map.get(min_score, det.label) || Map.get(min_score, "default", 0.5)
    det.score >= threshold
  end

  defp label_entries(entries, dets, started_at, observed_at) do
    t = DateTime.diff(observed_at, started_at, :millisecond) / 1000

    new =
      for det <- dets do
        %{
          t: Float.round(max(t, 0.0), 1),
          label: det.label,
          score: det.score,
          object_id: det.object_id
        }
      end

    Enum.take(entries ++ new, @max_label_entries)
  end

  defp max_scores(acc, dets) do
    Enum.reduce(dets, acc, fn det, acc ->
      Map.update(acc, det.label, det.score, &max(&1, det.score))
    end)
  end

  # The event's single highest-scoring detection, kept with its bbox and time
  # offset — the frame the snapshot is cut from (see Cairn.Snapshot). Keeps the
  # incumbent on ties so the earliest such detection wins.
  defp best_trigger(current, dets, t) do
    Enum.reduce(dets, current, fn det, best ->
      if is_nil(best) or det.score > best.score do
        %{
          t: Float.round(max(t, 0.0), 2),
          label: det.label,
          score: det.score,
          bbox: det.bbox,
          object_id: det.object_id
        }
      else
        best
      end
    end)
  end

  defp schedule(kind, camera_id, event_id, seconds) do
    token = make_ref()
    tref = Process.send_after(self(), {kind, camera_id, event_id, token}, seconds * 1_000)
    {tref, token}
  end

  # `:camera_stopped` announces the end of a stream — nothing will ever decode
  # under that epoch. Dropping the entry instead of storing it is what keeps
  # `epochs` from growing one row per camera ever removed.
  defp remember_epoch(state, camera_id, _epoch, :camera_stopped),
    do: %{state | epochs: Map.delete(state.epochs, camera_id)}

  defp remember_epoch(state, camera_id, epoch, _reason),
    do: %{state | epochs: Map.put(state.epochs, camera_id, epoch)}

  # State created here starts on the camera's last announced epoch, so a
  # repeat of that announcement is recognised as one and cuts nothing.
  defp cam_state(state, camera_id),
    do: state.cameras[camera_id] || new_cam(state.epochs[camera_id])

  defp new_cam(current_epoch \\ nil) do
    %{
      event: nil,
      extractor: nil,
      tracker: Tracker.new(),
      track_updates: %{},
      current_epoch: current_epoch,
      # last seen in `process_detections/5`; see the comment there
      policy: nil,
      camera: nil,
      checkpointed_at: nil,
      post_ref: nil,
      post_token: nil,
      max_ref: nil,
      max_token: nil
    }
  end

  defp clear_event(cam) do
    if cam.post_ref, do: Process.cancel_timer(cam.post_ref)
    if cam.max_ref, do: Process.cancel_timer(cam.max_ref)

    %{
      cam
      | event: nil,
        extractor: nil,
        checkpointed_at: nil,
        post_ref: nil,
        post_token: nil,
        max_ref: nil,
        max_token: nil
    }
  end

  defp put_cam(state, camera_id, cam) do
    %{state | cameras: Map.put(state.cameras, camera_id, cam)}
  end

  defp now, do: DateTime.utc_now()
end
