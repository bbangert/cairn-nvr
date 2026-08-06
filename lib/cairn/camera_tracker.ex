defmodule Cairn.CameraTracker do
  @moduledoc """
  Owns one camera's event lifecycle — one process per camera, one active event.

  Receives decoded `Cairn.Observation`s from `Cairn.PluginPort` /
  `Cairn.PluginGroupPort`, filters by per-label `min_score` and the camera's
  `record:` tier, assigns stable object identities (`Cairn.Tracker`, ULID
  strings), and:

    * no active event + evidence -> starts a `Cairn.EventExtractor` and
      broadcasts `{:event_started, event}` on `"events"`
    * evidence during an event -> accumulates time-indexed labels, resets
      the post-window timer, broadcasts `{:event_updated, event}`
    * `post_window` seconds of quiet -> finalizes; `max_event` seconds ->
      finalizes and lets the next piece of evidence open a fresh event

  One process per camera, registered as `Cairn.Registry.via(camera_id,
  :camera_tracker)` and started on demand by `ensure/1` under
  `Cairn.TrackerSupervisor` — deliberately *outside* the per-camera media tree,
  so restarting a camera's ffmpeg or plugin does not take its tracking state
  with it. The process is `:transient`: a crash restarts it and the fresh
  process restores from `Cairn.EventCheckpoint` in `init/1` — so the
  `:host_restart` finals a checkpoint owes go out immediately, not when the
  camera's next observation happens to arrive (a camera whose stream died with
  its tracker would otherwise strand them indefinitely). The clean stop that is
  not restarted is the app shutting down; removing a camera does not stop this
  process — the `:camera_stopped` epoch ends its tracks and the idle tracker
  lingers until shutdown.

  Not every detection is evidence (`evidence?/3`, the one gate both of the
  first two bullets pass through): a predicted ("tracked") object is refused,
  and so is one whose track the tracker has judged **stationary**. A parked car
  therefore stops resetting the post-window, the event closes on schedule and
  stays closed — nothing reopens it while the car sits there — and the car is
  evidence again the moment it moves.

  The camera's `record:` tier refuses on the detection itself rather than on
  its track: a present block is the whitelist of what earns video, applied on
  top of the `min_score` floor, so a label it leaves out never opens or extends
  an event however high it scores. An absent block is the older behaviour —
  everything the floor admits records.

  `{:event_ended, event}` means the detection window closed and nothing more:
  it is broadcast before the extractor is even told to finalize, so the clip
  is still being written and the snapshot does not exist. The media itself is
  announced by `Cairn.EventArtifact`.

  Event times come from the observation rather than from any clock read here:
  `started_at`, `labels[].t` and `trigger.t` derive from
  `observation.observed_at`, which a v1 plugin captured next to the frame. The
  host's own clocks are still what *close* an event — `ended_at` in wall time,
  the post-window and max-event timers in monotonic — because quiet produces no
  observations to measure quiet with.

  Track lifecycle is published on the same `"events"` topic as
  `%Cairn.Track{}` summaries: `track_started` and `track_ended` always,
  `track_updated` only when the track's best score improves or a second on the
  host's monotonic clock has passed since its last update — a default-rate (5 fps)
  stream with a dozen
  objects must not become a firehose of identical frames. Two `track_updated`
  frames ignore the throttle: a stationary transition, because the flag decides
  whether the object is evidence and a consumer must not learn of the flip up
  to a second after this module has already acted on it; and a track resuming
  after a stream reset, which is the frame carrying its new `epoch`.

  The same lifecycle feeds the track index through `Cairn.TrackRecorder`:
  `:appeared` and the stationary flips are buffered as timeline moments, and
  the track itself is handed over in three kinds of write — opened as a live
  row the moment it first passes the camera's `track:` tier, refreshed on every
  update the throttle lets through, and closed when it ends. Everything sent
  there is a cast — this process never touches `Cairn.Repo` on the detection
  path.

  The tier alone gates *opening* a row, so a track that never reaches it never
  has one while it runs. What ends up in the table is gated more loosely, and
  deliberately: at the end a track live during an open event is recorded
  unconditionally with that event's id, and so is one that already has a row,
  whatever the tier says by then (see `record_final/2`). Recording being
  disabled at runtime does not enter into it: rows without video are the point
  of the two tiers.

  While an event is open, the tagged boxes of every batch are also cast to
  that event's `Cairn.EventExtractor`, which buffers them and writes the dense
  track-path sidecar next to the clip when it finalizes (`Cairn.TrackPath`).
  Those casts are unfiltered where everything above is filtered — a path is
  drawn for objects that never earned video, predicted and stationary ones
  included — and their delivery order relative to the finalize cast is what
  keeps the last batch of an event; see `forward_boxes/3`.

  Subscribes to `Cairn.StreamEpochs` and keeps only its own camera's
  announcements: a new epoch **suspends** the live tracks rather than ending
  them (`Cairn.Tracker.suspend/3`), so a detection in the new stream can adopt
  an identity the outage interrupted instead of minting a second one for the
  same parked car. What adoption demands of it, and what it resumes, is the
  tracker's moduledoc. A suspension nothing adopts inside the window ends
  `:stream_reset` — on a later batch, or on this process's own timer when the
  stream never returns — with the timestamps it had at the cut. A camera that
  *stops* ends everything at the boundary instead: nothing is coming that could
  adopt it. Turning detection off at runtime ends both sets
  (`:detection_disabled` for the live ones, `:stream_reset` for anything still
  suspended) — nothing would advance them while it is off.

  The active event is checkpointed to `Cairn.EventCheckpoint` (ETS owned
  elsewhere, so it survives this process) together with the tracks live *and*
  suspended at that moment: a replacement process re-attaches to a live
  extractor, finalizes an orphan, and ends every restored track
  (`:host_restart`) — broadcasting it and recording it against the
  checkpointed event, the open-event rule above. A suspension cannot outlive
  the tracker that would have adopted it, so it dies there with the rest.
  Writes are throttled to one a second apart from the event's first and last.
  How far that reaches, and what it does not cover, is `Cairn.Track`'s
  moduledoc.
  """

  use GenServer, restart: :transient

  require Logger

  alias Cairn.{CameraControl, Config, Event, EventCheckpoint, Events, Observation, StreamEpochs}
  alias Cairn.{Track, Tracker, TrackRecorder}

  @max_label_entries 5_000
  # The host's own clock, deliberately: it throttles what a subscriber
  # receives, which has nothing to do with how fast the stream is arriving.
  # The observation clock would do — it is anchored to this one — but it lags a
  # stalled stream, and a subscriber's update rate must not lag with it.
  @update_throttle_ms 1_000
  # The checkpoint row is a deep ETS copy of the whole `%Event{}` (labels grow
  # to @max_label_entries) plus a freshly built, sorted track list, and it was
  # rewritten on every observation batch. It exists only so a replacement
  # process can re-attach to a live extractor and emit finals, and a recovered
  # event is written `:partial` either way — so losing the last second of
  # labels costs nothing that the recovery does not already cost. The two
  # transitions that *do* matter for restore are exempt: the first write at
  # event start, and the delete at event end.
  @checkpoint_throttle_ms 1_000

  @doc """
  Starts the tracker for one camera.

  `:camera_id` is required. `:name` defaults to this camera's registered
  via-tuple; `nil` starts it unregistered, which is how a test drives one
  directly. The remaining options (`:start_extractor`, `:finalize_extractor`,
  `:recorder`, `:monotonic_ms`, `:window_ms`, `:cut_clock`) are injection
  seams documented at their defaults in `init/1`.
  """
  def start_link(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)

    case Keyword.get(opts, :name, Cairn.Registry.via(camera_id, :camera_tracker)) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  The tracker for `camera_id`, started under `Cairn.TrackerSupervisor` if it
  is not running yet.

  The registry read is a stale-read site (see
  `.claude/solutions/registry-stale-read-at-decision-sites-20260728.md`), and
  it errs toward inaction on purpose: an entry the registry has not reaped yet
  hands back a dead pid, the cast that follows is a no-op, and one batch of
  detections is lost. What replaces the corpse is usually the supervisor: the
  child is `:transient`, so by the next batch the registry answers with the
  restarted tracker. Starting one from here is the fallback for the deaths the
  supervisor does not undo — a clean stop, or a pool that spent its restart
  intensity. Nothing here polls for that, because a detection dropped during a
  tracker's death is indistinguishable from one dropped by its crash.

  `DynamicSupervisor.start_child/2` is a `call`, so it *exits* when the
  supervisor is down (its own restart window). This runs in a plugin port, and
  a port must not die because the tracker tree is briefly absent — the exit is
  caught and reported as an error instead.
  """
  @spec ensure(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure(camera_id) do
    case Cairn.Registry.whereis(camera_id, :camera_tracker) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> start_tracker(camera_id)
    end
  end

  defp start_tracker(camera_id) do
    spec = {__MODULE__, camera_id: camera_id}

    case DynamicSupervisor.start_child(Cairn.TrackerSupervisor.Pool, spec) do
      {:ok, pid} -> {:ok, pid}
      # something got there first: the supervisor's own restart of a
      # `:transient` child, another port, or the checkpoint restore sweep
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Called by the plugin ports with a decoded, config-tagged observation.

  `policy` is `Cairn.Config.policy/2` for the camera: the event windows, the
  tracking settings and the host-side `track:` / `record:` tiers, resolved at
  the port so this per-frame path never calls the config server.

  Routes to the camera's own tracker, starting it if this is the first batch.
  """
  @spec detections(Cairn.Config.Camera.t(), map(), Observation.t()) :: :ok
  def detections(camera, policy, %Observation{} = observation) do
    case ensure(camera.id) do
      {:ok, pid} ->
        GenServer.cast(pid, {:detections, camera, policy, observation})

      {:error, reason} ->
        Logger.debug("camera #{camera.id}: no tracker for this batch (#{inspect(reason)})")
        :ok
    end
  end

  @doc """
  `detections/3` addressed to an explicit process — the ports' injection seam,
  where a test substitutes itself for the camera's tracker and inspects the
  cast. `nil` means "the camera's own tracker", i.e. `detections/3`.
  """
  @spec detections(GenServer.server() | nil, Cairn.Config.Camera.t(), map(), Observation.t()) ::
          :ok
  def detections(nil, camera, policy, observation), do: detections(camera, policy, observation)

  def detections(server, camera, policy, %Observation{} = observation),
    do: GenServer.cast(server, {:detections, camera, policy, observation})

  @doc """
  Starts a tracker for every camera holding a checkpointed event, so a restore
  does not wait for that camera's next observation.

  Runs as the second child of `Cairn.TrackerSupervisor`, after the tracker
  pool. At boot it is always a no-op: `Cairn.EventCheckpoint`'s table is ETS,
  so it dies with the VM and is created empty a few children earlier in the
  same start sequence. It earns its keep on a pool restart, where the rows
  outlive every tracker that wrote them and the subtree's `:rest_for_one`
  cascade re-runs this.
  """
  @spec restore_checkpointed() :: :ok
  def restore_checkpointed do
    Enum.each(EventCheckpoint.all(), fn {camera_id, _event, _tracks} -> ensure(camera_id) end)
  end

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)

    # Subscribe before reading, never after: a mint landing between the two is
    # then delivered as a message rather than missed, and the worst case is
    # applying the epoch twice — which `apply_epoch/3` recognises as a repeat
    # and does nothing with.
    StreamEpochs.subscribe()

    state = %{
      camera_id: camera_id,
      event: nil,
      extractor: nil,
      tracker: Tracker.new(),
      track_updates: %{},
      current_epoch: seed_epoch(camera_id),
      # the wall instant the last stream reset cut this camera off at, held
      # only until the first observation of the new epoch measures the gap to
      # it (`report_gap/2`)
      gap_from: nil,
      # the pending `:adoption_window` sweep, so arming the next one cancels
      # it. Not event state: `clear_event/1` leaves it alone, because a
      # suspension outlives the event that happened to be open at the cut.
      window_ref: nil,
      # last seen in `process_detections/5`; see the comment there
      policy: nil,
      camera: nil,
      checkpointed_at: nil,
      post_ref: nil,
      post_token: nil,
      max_ref: nil,
      max_token: nil,
      start_extractor: Keyword.get(opts, :start_extractor, &Cairn.EventExtractor.start/2),
      finalize_extractor:
        Keyword.get(opts, :finalize_extractor, &Cairn.EventExtractor.finalize/2),
      # The track index's batch writer, injectable for the same reason as the
      # two above. Everything sent to it is a cast, so this path never waits on
      # the database — see `Cairn.TrackRecorder`.
      recorder: Keyword.get(opts, :recorder, TrackRecorder),
      # injectable so the update throttle can be tested without sleeping
      monotonic_ms: Keyword.get(opts, :monotonic_ms, &default_monotonic_ms/0),
      # How long after a stream reset this process sweeps the suspensions the
      # tracker is holding. Injectable for the same reason: the real delay is
      # the adoption window plus slack, and no test should sit through a
      # minute of it to prove the sweep is armed.
      window_ms: Keyword.get(opts, :window_ms, Tracker.adoption_window_ms() + 1_000),
      # The observation-clock instant a stream cut is stamped with, which is
      # what the tracker measures the adoption window from. The same clock
      # `monotonic_ms` reads — both default to the real one — and injectable
      # separately for the reason `window_ms` is: the window is a minute, so a
      # test proving a suspension lapses has to be able to put the cut a minute
      # in the past while leaving the sweep on the real clock, the two being
      # what an elapsed time is taken between.
      cut_clock: Keyword.get(opts, :cut_clock, &default_monotonic_ms/0)
    }

    {:ok, restore_from_checkpoint(state)}
  end

  # The epoch this camera is streaming under right now, if anything is: it is
  # minted at ffmpeg spawn, long before the first detection creates this
  # process, so reading it here is what lets `stale?/2` judge the very first
  # batch and what makes the next announcement of the same epoch a no-op.
  defp seed_epoch(camera_id) do
    case StreamEpochs.current(camera_id) do
      {:ok, epoch} -> epoch
      :unknown -> nil
    end
  end

  @impl true
  def handle_cast(
        {:detections, %{id: camera_id} = camera, policy, observation},
        %{camera_id: camera_id} = state
      ) do
    control = CameraControl.get(camera_id)
    observation = observation |> with_observed_at() |> with_at_ms(state)

    cond do
      not control.detection_enabled ->
        # detection disabled at runtime: drop the batch, and retire whatever
        # was live — nothing will advance those tracks while detection is off,
        # so leaving them "live" would strand every consumer's entities and
        # keep their throttle state resident. An in-flight event is left to
        # finalize naturally on its post-window timer.
        {:noreply, end_tracks_disabled(state)}

      stale?(state, observation) ->
        {:noreply, state}

      true ->
        {:noreply, process_detections(state, camera, policy, observation, control)}
    end
  end

  # A batch addressed to another camera. The ports route through `ensure/1` on
  # the observation's own camera, so this is a misroute rather than a race —
  # dropped and said out loud, never folded into this camera's tracker.
  def handle_cast({:detections, camera, _policy, _observation}, state) do
    Logger.warning(
      "camera #{state.camera_id}: dropped a batch addressed to " <>
        "#{inspect(Map.get(camera, :id))}"
    )

    {:noreply, state}
  end

  # Invariant: every observation leaving a port carries a `%DateTime{}` — the
  # codec parses one for v1 and the port stamps arrival for v0 — and every
  # time in an event derives from it. `detections/3` is a public entry point
  # any caller can reach, so a `nil` slipping through must not be a
  # `FunctionClauseError` in `DateTime.diff/3` here.
  defp with_observed_at(%Observation{observed_at: at} = observation)
       when is_struct(at, DateTime),
       do: observation

  defp with_observed_at(observation), do: %{observation | observed_at: now()}

  # The same invariant for the clock the tracker decides on: the ports stamp
  # every observation they forward (`Cairn.ObservationClock`), and a caller
  # reaching `detections/3` directly must not put a `nil` into the tracker's
  # arithmetic. Falling back to the host clock is honest but coarse — it dates
  # the batch's *arrival* and carries none of the spacing between frames that
  # the ports' clock takes from the pts, nor its non-decreasing clamp; the
  # test seams that are this fallback's only callers accept both.
  defp with_at_ms(%Observation{at_ms: at_ms} = observation, _state) when is_number(at_ms),
    do: observation

  defp with_at_ms(observation, state), do: %{observation | at_ms: state.monotonic_ms.()}

  # Belt and braces: the ports already refuse observations from an epoch that
  # is no longer current, and this closes the window where a port's line and
  # the epoch broadcast cross. Compared against the same `current_epoch` the
  # epoch broadcast maintains, seeded in `init/1` from the epoch this camera
  # was already streaming under.
  #
  # An observation with no epoch (v0 before the first ffmpeg spawn) is
  # accepted, as is one for a camera whose epoch is not known here yet: that
  # first observation's epoch is adopted in `process_detections/5`.
  defp stale?(_state, %Observation{epoch: nil}), do: false

  defp stale?(%{current_epoch: nil}, _observation), do: false
  defp stale?(%{current_epoch: epoch}, %Observation{epoch: epoch}), do: false

  defp stale?(state, %Observation{epoch: epoch}) do
    # Rare by construction, so it is counted rather than logged per line:
    # a steady rate here means a port is forwarding across a boundary.
    #
    # The event name is `:aggregator` for a wire-compatibility reason and not
    # an accidental one: it is what dashboards and alerts already match on,
    # and renaming it would silently blind them.
    :telemetry.execute([:cairn, :aggregator, :stale_observation], %{count: 1}, %{
      camera_id: state.camera_id
    })

    Logger.debug("camera #{state.camera_id}: dropped observation from stale epoch #{epoch}")
    true
  end

  defp process_detections(state, camera, policy, observation, control) do
    # One binding, read twice: the tracker partitions this batch against the
    # floor (below it a box may match a live track but never mint one), and
    # `evidence?/3` below gates what may open an event on the same number. They
    # have to be the same number — a box that may earn video but may not mint
    # the track carrying it would be an event with no identity behind it.
    min_score = effective_min_score(camera, control)

    context =
      Tracker.context(
        observation,
        camera.id,
        Map.put(tracking_policy(policy), :min_score, min_score)
      )

    {tracker, tagged, track_events} = Tracker.track(state.tracker, observation.objects, context)

    state =
      %{
        state
        | tracker: tracker,
          current_epoch: state.current_epoch || observation.epoch,
          # Cached for the track rows, and set before the events of this batch
          # are published so a track ending in it is gated on this batch's
          # policy. The ended-track paths that need them — `apply_epoch/3`,
          # `end_tracks_disabled/1`, checkpoint restore — are handed neither a
          # camera nor a policy, and reaching for the config server there would
          # put a call on a path an epoch broadcast drives.
          policy: policy,
          camera: camera
      }
      |> report_link(observation, track_events)
      |> publish_tracks(track_events)

    # A predicted ("tracked") object, a track the plugin keeps predicting long
    # after anything last detected it, and a track that has held still past the
    # camera's `stationary_after_ms` are all not evidence: they keep the
    # tracker warm but can neither open an event nor hold one open. Nor is a
    # detection the camera's `record:` tier does not admit.
    #
    # `Map.get/2` for the same reason as `tracking_policy/1`: `detections/3` is
    # a public entry point any caller can hand a bare map, and a missing key
    # has to read as an absent block rather than raise on this path.
    record_tier = Map.get(policy, :record)
    passing = Enum.filter(tagged, &evidence?(&1, min_score, record_tier))

    state =
      cond do
        passing == [] -> state
        # recording disabled: evaluate detections but don't open a new event
        state.event == nil and not control.recording_enabled -> state
        state.event == nil -> start_event(state, camera, policy, observation, passing)
        true -> update_event(state, policy, observation, passing)
      end

    # After the lifecycle `cond` and on its result, deliberately: the batch
    # that opens an event is part of that event's path (at `t_ms` 0), and
    # before the `cond` `state.event` would still be nil for it.
    forward_boxes(state, observation, tagged)

    state
  end

  # The dense half of the track viewer: every tagged box of an open event, in
  # the compact shape `Cairn.TrackPath` reads (`box_entry`).
  #
  # Deliberately unfiltered — no `min_score`, no `record:` tier, predicted and
  # stationary objects kept — because what earns video is a different question
  # from what is drawn over video already recorded, and a path with holes in it
  # reads as a second object rather than as a gap.
  #
  # One path may now span a stream reset: an identity adopted out of suspension
  # keeps its ULID, so its samples continue across the splice in the clip. They
  # stay ordered and drawable — `t_ms` is wall-clock offset from the event's
  # start, not media time, so nothing here reads the pts that restarted — but
  # the clip's own media timeline is non-monotonic past the splice, and any
  # pts-anchored alignment of boxes to frames degrades after it. That is a
  # property of the spliced clip and not of this list; it predates adoption,
  # which only means a single track id can now be on both sides of it.
  #
  # The other gap is upstream: a box `Cairn.Tracker` refused and suppressed
  # as a duplicate never reaches `tagged` at all, and cannot, because it has no
  # `object_id` to draw it under. That is the trade the tracker makes on
  # purpose — a gap in one path, rather than a second path over the same
  # object for as long as the duplicate identity lives.
  #
  # **Ordering dependency.** "No last batch is lost" rests on one fact: this
  # cast and the finalize cast in `maybe_finalize/3` share a sender *and* a
  # receiver, and the BEAM orders messages per sender/receiver pair — so every
  # batch sent before finalize is in the extractor's mailbox before it. If
  # finalize ever becomes a `call`, moves to another process, or travels by
  # PubSub, the sidecar silently loses however much of its tail the scheduler
  # decided to, with nothing raised and nothing logged.
  #
  # A cast to an extractor that has already exited is a no-op, so nothing here
  # checks whether the pid is alive.
  defp forward_boxes(%{event: %Event{} = event, extractor: pid}, observation, tagged)
       when is_pid(pid) do
    GenServer.cast(
      pid,
      {:track_boxes,
       %{
         t_ms: DateTime.diff(observation.observed_at, event.started_at, :millisecond),
         boxes: Enum.map(tagged, &{&1.object_id, &1.label, &1.bbox, &1.stationary})
       }}
    )
  end

  defp forward_boxes(_state, _observation, _tagged), do: :ok

  # The single gate: the objects this accepts are `passing`, which is what both
  # `start_event/5` and `update_event/4` are handed, so what is refused here
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
  defp evidence?(object, min_score, record_tier) do
    Observation.detected?(object) and not object.stationary and
      earns_video?(object, min_score, record_tier)
  end

  # No `record:` block: the (possibly overridden) `min_score` floor decides
  # alone, and everything it admits earns video.
  defp earns_video?(object, min_score, nil), do: passes_min_score?(object, min_score)

  # Where the runtime `control.min_score` override and the config tier meet.
  # They answer different questions — the tier says whether this label at this
  # score deserves video, the override raises or lowers the floor right now —
  # so evidence needs **both**: `score >= max(effective_min_score, tier)`, with
  # `:excluded` beating any floor. An override can therefore raise the bar at
  # runtime, but never un-exclude a label or undercut a tier.
  #
  # With no override in force the floor half is implied rather than load-
  # bearing: a tier below the camera's *configured* `min_score` is a load-time
  # error, so clearing the tier already clears the floor. The override is what
  # makes the `max` bite — it goes through no such validation and can land
  # either side of a tier (see `Cairn.Config.tier_threshold/3`).
  defp earns_video?(object, min_score, rules) do
    case Config.tier_threshold(rules, object.label, min_score) do
      :excluded -> false
      threshold -> passes_min_score?(object, min_score) and object.score >= threshold
    end
  end

  # Defensive on a public, @spec'd entry point (`detections/3`) that any caller
  # can hand a bare map: the tracker's bounds must not silently become nil.
  defp tracking_policy(policy) do
    base = %{
      max_unseen_ms: Map.get(policy, :max_unseen_ms) || Config.default_max_unseen_ms(),
      max_live_tracks: Map.get(policy, :max_live_tracks) || Config.default_max_live_tracks(),
      stationary_after_ms:
        Map.get(policy, :stationary_after_ms) || Config.default_stationary_after_ms(),
      # `Map.get/3` where its three neighbours use `||`: these two are booleans,
      # and `||` would read an explicit `false` as an absent key — the same
      # answer only for as long as the default is `false`.
      bbd: Map.get(policy, :bbd, Config.default_bbd()),
      oru: Map.get(policy, :oru, Config.default_oru())
    }

    # A profiled camera's policy carries a stage presence map, and it rides
    # this hop unmodified — `Cairn.Tracker.context/3` is where it supersedes
    # the booleans above. Absent for every unprofiled camera, whose map stays
    # exactly the pre-profile one.
    case Map.get(policy, :stages) do
      nil -> base
      stages -> Map.put(base, :stages, stages)
    end
  end

  # Detection off ends every track outright: nothing will observe this camera
  # again until it is turned back on, so there is nothing left to wait for and
  # no suspension to offer (that is the epoch cuts' business, below).
  defp end_tracks_disabled(state) do
    case Tracker.end_all(state.tracker, :detection_disabled) do
      {tracker, [_ | _] = ended} ->
        publish_tracks(%{state | tracker: tracker}, ended)

      # nothing live: the second disabled batch onwards is a no-op, and the
      # tracker is left alone rather than replaced.
      _ ->
        state
    end
  end

  # A runtime min_score override replaces the camera's configured thresholds
  # (applied as the default for every label); nil means "use config". It moves
  # the floor and only the floor — the `record:` tier applies on top of
  # whatever comes out of here (see `earns_video?/3`).
  defp effective_min_score(camera, %{min_score: nil}), do: camera.min_score
  defp effective_min_score(_camera, %{min_score: override}), do: %{"default" => override}

  @impl true
  def handle_info({:post_window, event_id, token}, state) do
    # the token guards against a stale timer message that was already in
    # the mailbox when a detection cancelled + rescheduled the window
    if token == state.post_token do
      {:noreply, maybe_finalize(state, event_id, :post_window)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:max_event, event_id, token}, state) do
    if token == state.max_token do
      {:noreply, maybe_finalize(state, event_id, :max_event)}
    else
      {:noreply, state}
    end
  end

  # A new epoch is a new continuous decode. Nothing observed the gap, so no
  # track may go on matching *ordinarily* across it — but most of the time the
  # objects either side are the same objects, and ending them all was itself a
  # defect: a parked car severed by a 300 ms reconnect re-minted, spent its
  # settle window looking like a new arrival, and that is evidence, and
  # evidence is a clip. The live tracks are therefore suspended (see the
  # moduledoc and `Cairn.Tracker.suspend/3`) and only what cannot be adopted —
  # a generation of ghosts the cap pushed out, a suspension whose window
  # already lapsed — gets a final summary here. An in-flight event keeps
  # running and finalizes on its own timers.
  #
  # Detection casts already in flight when this arrives are processed *after*
  # the reset: they come from the plugin ports, not from `Cairn.StreamEpochs`,
  # and the BEAM only orders messages per sender pair, so a batch from before
  # the boundary would otherwise seed the fresh tracker. The epoch now travels
  # with the batch — tagged at the producer, compared in `stale?/2` against the
  # `current_epoch` stored here — so such a batch is dropped instead.
  # An epoch older than the one already held is ignored (see
  # `Cairn.ULID.superseded?/2`): applying it would roll `current_epoch` back
  # to a stream nothing decodes under, and `stale?/2` would then drop every
  # observation the ports still forward — a silent, sustained outage for this
  # camera until its next mint.
  #
  # The topic carries every camera's mints; only this camera's are ours.
  def handle_info({:stream_epoch, camera_id, epoch, reason}, %{camera_id: camera_id} = state) do
    if Cairn.ULID.superseded?(state.current_epoch, epoch) do
      {:noreply, state}
    else
      {:noreply, apply_epoch(state, epoch, reason)}
    end
  end

  # A suspension is collected by whatever comes first — a batch, another reset,
  # or this. It exists for the case where nothing comes first: a camera whose
  # stream never returns produces no observations to notice the window running
  # out on, and its consumers would wait forever for a final summary the
  # tracker is still holding.
  #
  # Deliberately unguarded by a token, unlike the event timers. A token there
  # keeps a stale message from finalizing the *current* event, which is a
  # different event from the one the message named; this message names no
  # suspension, and the sweep ends whatever has actually lapsed and nothing
  # else, so running it early or twice is a map walk with no result. What it
  # is guarded by is `window_ref`: `window_timer/1` cancels the pending sweep
  # before arming the next, so this camera holds one *armed* timer rather than
  # one per reset however fast it flaps. A message already in the mailbox when
  # the cancel lands is still delivered — which is the harmless case above.
  #
  # It re-arms while anything is still suspended, and that is what keeps the
  # harmless case above from stranding one. A sweep already in the mailbox when
  # `window_timer/1` cancels its timer still arrives, and this handler clears
  # `window_ref` when it does — losing the reference to the timer the reset had
  # just armed, which then fires untracked. The re-arm is what puts a tracked
  # one back. Its cost in the normal case is one extra hop that finds nothing
  # and arms nothing, because the sweep that lapses the last suspension leaves
  # none behind. This timer and the cut it sweeps against are both the host's
  # monotonic clock (`Cairn.Tracker.suspend/3` is handed `cut_clock`), so the
  # sweep cannot land before the window it is waiting on. A batch measures the
  # same window on its own `at_ms`, which never runs ahead of that clock — so
  # of the two, this is never the later to notice a lapse.
  def handle_info(:adoption_window, state) do
    {tracker, lapsed} = Tracker.expire_suspended(state.tracker, state.monotonic_ms.())

    state =
      %{state | tracker: tracker, window_ref: nil}
      |> publish_tracks(lapsed)
      |> rearm_window()

    report_expired(state.camera_id, lapsed)
    {:noreply, state}
  end

  # `:noproc` is a clean finish, not a crash. `restore_from_checkpoint/1` can
  # monitor a pid the registry still lists but whose process is already gone
  # (unregistration rides the async DOWN the partition sends itself), and
  # `Process.monitor/1` on a corpse answers `:noproc` immediately. Treating it
  # as a crash logs a cleanly finalised event as crashed and re-announces it as
  # `:partial` in the event index.
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{extractor: pid} = state)
      when reason not in [:normal, :noproc] do
    case state.event do
      %Event{} = event ->
        Logger.warning("event #{event.id}: extractor crashed (#{inspect(reason)})")
        EventCheckpoint.delete(state.camera_id)
        Event.broadcast(:event_ended, %{event | status: :partial, ended_at: now()})
        {:noreply, clear_event(state)}

      nil ->
        {:noreply, clear_event(state)}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{extractor: pid} = state),
    do: {:noreply, clear_event(state)}

  def handle_info(_msg, state), do: {:noreply, state}

  # `:camera_stopped` names the end of a stream, not the start of one: nothing
  # will ever decode under that epoch. It ends the live tracks and any
  # suspended ones (the stream they belong to is over, so nothing is coming
  # that could adopt them) but must never become `current_epoch` — the stop
  # and the start of one camera are announced by different processes, and on the
  # degraded caller-side broadcast path they have no ordering relation, so a
  # stop epoch minted after a live `:started` could otherwise be adopted as
  # current and `stale?/2` would then drop every observation of a *healthy*
  # camera until its next ffmpeg respawn — which is not coming.
  #
  # `current_epoch` is cleared rather than kept: this camera is not streaming
  # under anything, so there is no epoch a straggling observation could be
  # judged against, and holding the dead one would drop the first batch of a
  # stream that came back before its mint was announced. The next mint seeds it
  # again.
  defp apply_epoch(state, _epoch, :camera_stopped) do
    {tracker, ended} = Tracker.end_all(state.tracker, :stream_reset)

    publish_tracks(
      %{state | tracker: tracker, current_epoch: nil, gap_from: nil},
      ended
    )
  end

  # One mint can be announced twice by design: `Cairn.StreamEpochs` broadcasts
  # from the caller when its server is unreachable, and a call that exited with
  # :timeout may still be served afterwards. The epoch is the same either way,
  # so a repeat means no boundary was crossed — ending every live track again
  # would cut them mid-stream. The repeat is caught even for the mint that
  # predates this process: `init/1` seeds `current_epoch` from the epoch table.
  defp apply_epoch(%{current_epoch: epoch} = state, epoch, _reason), do: state

  defp apply_epoch(state, epoch, reason) do
    {tracker, ended, suspension} =
      Tracker.suspend(state.tracker, max_suspended(state), state.cut_clock.())

    Logger.info(
      "camera #{state.camera_id}: stream reset (#{reason}) — #{suspension.suspended} track(s) " <>
        "suspended for adoption, #{suspension.ended} ended"
    )

    :telemetry.execute(
      [:cairn, :tracker, :stream_reset],
      %{suspended: suspension.suspended, ended: suspension.ended},
      %{camera_id: state.camera_id, reason: reason}
    )

    %{state | tracker: tracker, current_epoch: epoch, gap_from: suspension.at}
    |> rearm_window()
    |> publish_tracks(ended)
  end

  # -- link health ------------------------------------------------------------

  # The cap the suspended set is trimmed to. The same number as the live one on
  # purpose — a camera cannot suspend more tracks than it was allowed to hold —
  # and read from the cached policy for the reason `qualifies?/2` reads it
  # there: this runs on an epoch broadcast, which is handed no camera and no
  # policy, and the config server has no business on a path a flapping stream
  # drives.
  defp max_suspended(state), do: tracking_policy(state.policy || %{}).max_live_tracks

  # Armed only while this camera has something to sweep: a reset that suspends
  # nothing arms nothing, and the sweep that collects the last suspension does
  # not come back.
  defp rearm_window(state) do
    if Tracker.suspended_count(state.tracker) > 0, do: window_timer(state), else: state
  end

  # Past the window rather than at it: see the `:adoption_window` handler. The
  # pending sweep is cancelled first, so a camera resetting several times a
  # second holds one *tracked* timer rather than one per reset. Cancelling does
  # not recall a message already in the mailbox, and the handler that then runs
  # clears `window_ref` and re-arms — so an interleaving can leave this timer in
  # flight untracked beside the re-armed one. That is bounded (the handler
  # re-arms at most one) and harmless: the sweep ends whatever has actually
  # lapsed and nothing else, so an extra one is a map walk with no result.
  defp window_timer(state) do
    if state.window_ref, do: Process.cancel_timer(state.window_ref)
    ref = Process.send_after(self(), :adoption_window, state.window_ms)
    %{state | window_ref: ref}
  end

  # How the stream reset actually went, reported from the first batch that
  # follows it: the outage gap can only be measured once the far side produces
  # an observation to measure to. `gap_from` is the last observation before the
  # cut, and it is cleared here so the report is one line per reset and not one
  # per batch.
  #
  # Adoptions and lapses are counted off the same batch's events, which is
  # where the tracker reports them: an adoption is a track resuming its
  # identity, and a `:stream_reset` end arriving on a *batch* is a suspension
  # whose window ran out (the ones the reset itself severs are emitted by
  # `apply_epoch/3`, not here).
  defp report_link(state, observation, events) do
    report_adopted(state.camera_id, events)
    report_expired(state.camera_id, events)
    report_gap(state, observation)
  end

  defp report_gap(%{gap_from: nil} = state, _observation), do: state

  defp report_gap(state, observation) do
    gap = max(DateTime.diff(observation.observed_at, state.gap_from, :millisecond), 0)

    Logger.info("camera #{state.camera_id}: stream back after a #{gap} ms gap")

    :telemetry.execute([:cairn, :tracker, :stream_gap], %{gap_ms: gap}, %{
      camera_id: state.camera_id
    })

    %{state | gap_from: nil}
  end

  defp report_adopted(camera_id, events) do
    case Enum.count(events, &match?({:adopted, _track}, &1)) do
      0 ->
        :ok

      count ->
        Logger.info("camera #{camera_id}: #{count} track(s) adopted across the stream reset")
        :telemetry.execute([:cairn, :tracker, :adopted], %{count: count}, %{camera_id: camera_id})
    end
  end

  defp report_expired(camera_id, events) do
    case Enum.count(events, &match?({:ended, %Track{end_reason: :stream_reset}}, &1)) do
      0 ->
        :ok

      count ->
        Logger.info("camera #{camera_id}: #{count} suspended track(s) went unadopted")

        :telemetry.execute([:cairn, :tracker, :suspension_expired], %{count: count}, %{
          camera_id: camera_id
        })
    end
  end

  # -- track lifecycle --------------------------------------------------------

  # `track_started`, `track_ended`, the stationary transitions and an adoption
  # always go out: a subscriber that only ever sees the final summary still
  # learns what the track was, the flag this module gates evidence on must not
  # arrive late, and an identity resuming on a new epoch is not a frame a
  # throttle may swallow. Plain updates are throttled per track — best-score
  # improvement or a second of wall clock.
  defp publish_tracks(state, events) do
    Enum.reduce(events, state, fn
      {:started, track}, state ->
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

        note_update(state, track)

      {:updated, track}, state ->
        maybe_publish_update(state, track)

      {:ended, track}, state ->
        Track.broadcast(:track_ended, track)
        record_final(state, track)
        %{state | track_updates: Map.delete(state.track_updates, track.object_id)}

      # An identity resumed across a stream reset, which downstream never
      # learned had been interrupted: no `track_started` (it started when it
      # started) and nothing to un-say. It is published as a `track_updated`
      # and noted, taking the same throttle bypass as the stationary flips for
      # a reason of its own — this is the one frame carrying the track's new
      # `epoch`, and a row still naming the stream that died reads as stale.
      # No timeline moment: `Cairn.Tracks.TrackEvent`'s kinds are what a viewer
      # draws over a clip, and this happened between two clips' worth of media.
      {:adopted, track}, state ->
        Track.broadcast(:track_updated, track)
        note_update(state, track)

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
      {kind, track}, state when kind in [:became_stationary, :started_moving] ->
        Track.broadcast(:track_updated, track)

        TrackRecorder.record_moment(
          state.recorder,
          track.object_id,
          track.last_seen_at,
          kind,
          track.bbox
        )

        note_update(state, track)
    end)
  end

  # Whether a finished track's row is closed or its buffer thrown away, and
  # with which event.
  #
  # **An open event records the track unconditionally.** Every track live
  # during a clip therefore has a row, which is the audit property the table
  # exists for: without it a camera whose `record:` block admits a label its
  # `track:` block excludes would produce clips whose contents cannot be
  # enumerated — a cat that triggers a clip through an absent `record:` block
  # would have no row while the video of it sits on disk.
  #
  # A row, not a link: `event_id` only names the event open at the instant the
  # track ended, so a track that outlives the clip it appeared in carries nil
  # or the *next* event's id. Reading a clip's contents back is a time-overlap
  # query (`Cairn.Tracks.overlapping_event/3`) for exactly that reason.
  #
  # At the end, the `track:` tier gates only the tracks no event was open for —
  # the audit trail of what the system saw and did not record, where the tier is
  # the knob for how much of it to keep.
  #
  # *Opening* a row is gated by the tier alone, event or no event (see
  # `record_live/2`), and the two gates are deliberately not the same. A track
  # under its camera's `track:` tier that is live during a clip therefore has no
  # row while it runs and gets one here, when it ends: the audit property is
  # about what the table says once a clip is complete, and the alternative —
  # opening a row for every object in frame during a recording — would put rows
  # in the index that the tier exists to keep out for as long as the event
  # happened to be open.
  #
  # Every end reason goes through the same rule. `:evicted`, `:stream_reset`,
  # `:detection_disabled` and `:host_restart` are the reasons a reader is most
  # likely to be investigating, and a row costs nothing.
  #
  # "Open" means open when the track ended: `publish_tracks/2` runs on the
  # state as it was before this batch, so a track that expires in the same
  # observation whose detections open a brand-new event is tier-gated, not
  # linked to that event. That is the right answer, not an artefact of the
  # ordering — a track expiring in this batch was by definition not detected in
  # it, so it contributed no evidence to the event those detections opened, and
  # the event it did belong to (if any) had already closed.
  #
  # One end is deliberately later than the death it reports: a suspension that
  # goes unadopted ends when its window runs out, up to a minute after the
  # reset its summary is timestamped at. So its `event_id` can name an event
  # that opened *after* the track was last seen — which changes nothing, since
  # the column was never how a clip's contents are read back (above), and the
  # timestamps in the row are the honest ones.
  defp record_final(%{event: %Event{id: event_id}} = state, track) do
    TrackRecorder.record_final(state.recorder, track, event_id)
  end

  # A track that already has a row is closed whatever the tier answers now.
  # The two are usually the same answer — `best_score` only grows, so a track
  # that crossed its threshold is still over it — but not always: a camera's
  # policy can be refreshed mid-track, and a track's label follows its latest
  # detection, so either can move the tier out from under a row that exists.
  # Leaving that row open would strand it as live until the next boot, and
  # deleting it is not on offer here (this process makes no Repo call). Closing
  # it is the only answer that leaves the table describing what happened.
  defp record_final(state, track) do
    if rowed?(state, track.object_id) or qualifies?(state, track) do
      TrackRecorder.record_final(state.recorder, track, nil)
    else
      TrackRecorder.discard(state.recorder, track.object_id)
    end
  end

  # The `track:` tier, resolved for one track. The gate on opening a row and,
  # for a track that never opened one, on writing it at the end.
  #
  # Belt and braces on the cached pair: every path that can produce a live
  # track today has been through `process_detections/5`, which caches both. A
  # tracker that has never seen a detection does exist — `ensure/1` is public
  # and `restore_checkpointed/0` starts one per checkpointed camera — but it
  # holds an empty `Cairn.Tracker`, so no track reaches here and the nil caches
  # are never read. An end path
  # that ever skips it must not silently exclude the track, so an absent
  # policy is read as an absent `track:` block, i.e. the label's wire floor
  # off a default camera.
  defp qualifies?(state, track) do
    camera = state.camera || %Config.Camera{id: track.camera_id}
    tier = state.policy && Map.get(state.policy, :track)

    case Config.tier_threshold(tier, track.label, camera.min_score) do
      :excluded -> false
      threshold when is_number(threshold) -> track.best_score >= threshold
    end
  end

  defp maybe_publish_update(state, track) do
    case Map.get(state.track_updates, track.object_id) do
      nil ->
        Track.broadcast(:track_updated, track)
        note_update(state, track)

      last ->
        if track.best_score > last.best_score or
             state.monotonic_ms.() - last.at >= @update_throttle_ms do
          Track.broadcast(:track_updated, track)
          note_update(state, track)
        else
          state
        end
    end
  end

  # The throttle's bookkeeping, and with it the track index's live row: every
  # call here is a moment a `%Track{}` went out on the wire — a mint, a
  # stationary flip, or an update the throttle released — so writing the row
  # from here gives it the rhythm of the broadcast rather than of the frame
  # rate. Nothing on this path touches the database — `Cairn.TrackRecorder`
  # takes casts and batches them.
  #
  # `rowed?` is this process's memory of having opened one. It is not
  # authoritative — the recorder owns that, and refuses an update for an id it
  # does not know — but it is what keeps the tier from being re-asked per
  # update, and what tells `record_final/2` that a row is out there needing to
  # be closed.
  defp note_update(state, track) do
    rowed? = record_live(state, track)
    entry = %{at: state.monotonic_ms.(), best_score: track.best_score, rowed?: rowed?}
    %{state | track_updates: Map.put(state.track_updates, track.object_id, entry)}
  end

  # A track's row is opened by the first update that finds it over the camera's
  # `track:` tier — at mint if it is already there, later if its `best_score`
  # climbs into it. A crossing driven by the score is never delayed by the
  # throttle: `maybe_publish_update/2` releases on any improvement in
  # `best_score`, and that is what a crossing is. A crossing driven by the
  # *threshold* moving instead — the track's label followed a new detection, or
  # the camera's policy was refreshed — waits for the next release, so at most
  # `@update_throttle_ms`.
  defp record_live(state, track) do
    cond do
      rowed?(state, track.object_id) ->
        TrackRecorder.record_update(state.recorder, track, open_event_id(state))
        true

      qualifies?(state, track) ->
        TrackRecorder.record_open(state.recorder, track, open_event_id(state))
        true

      true ->
        false
    end
  end

  defp rowed?(state, object_id),
    do: match?(%{rowed?: true}, Map.get(state.track_updates, object_id))

  # The event open right now, which for a live row is a best guess at the clip
  # it will be read against and is replaced on every write until the closing
  # one. Only that last value carries the column's documented meaning — the
  # event open when the track *ended* — and even it is not how a clip's contents
  # are read back (`Cairn.Tracks.overlapping_event/3` asks about time).
  defp open_event_id(%{event: %Event{id: id}}), do: id
  defp open_event_id(_state), do: nil

  defp default_monotonic_ms, do: System.monotonic_time(:millisecond)

  # -- lifecycle --------------------------------------------------------------

  defp start_event(state, camera, policy, observation, dets) do
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
        EventCheckpoint.put(camera.id, event, Tracker.checkpoint_tracks(state.tracker))
        Event.broadcast(:event_started, event)

        {post_ref, post_token} = schedule(:post_window, event.id, policy.post)
        {max_ref, max_token} = schedule(:max_event, event.id, policy.max)

        %{
          state
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
        state
    end
  end

  defp update_event(%{event: event} = state, policy, observation, dets) do
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

    if state.post_ref, do: Process.cancel_timer(state.post_ref)
    state = checkpoint(%{state | event: event})
    Event.broadcast(:event_updated, event)

    {post_ref, post_token} = schedule(:post_window, event.id, policy.post)
    %{state | post_ref: post_ref, post_token: post_token}
  end

  defp checkpoint(%{event: event} = state) do
    now = state.monotonic_ms.()

    if state.checkpointed_at == nil or now - state.checkpointed_at >= @checkpoint_throttle_ms do
      EventCheckpoint.put(event.camera_id, event, Tracker.checkpoint_tracks(state.tracker))
      %{state | checkpointed_at: now}
    else
      state
    end
  end

  defp maybe_finalize(%{event: %Event{id: event_id} = event} = state, event_id, cause) do
    Logger.info("event #{event.id} (#{state.camera_id}): finalizing (#{cause})")
    event = %{event | ended_at: now(), status: :finalized}
    # Ended first, then the extractor is told: the extractor's
    # `:event_clip_ready` can only follow the cast, so a subscriber is
    # guaranteed to learn the window closed before it learns the clip
    # landed. The reverse order lets a fast finalize overtake it.
    #
    # That this is a *cast from this process* is load-bearing beyond the
    # ordering above: it is what puts every `{:track_boxes, _}` this
    # process already sent (`forward_boxes/3`) ahead of it in the same
    # mailbox. A `call` here, or a finalize routed through anything else,
    # truncates the event's track path silently.
    Event.broadcast(:event_ended, event)
    state.finalize_extractor.(state.extractor, event)
    EventCheckpoint.delete(state.camera_id)
    clear_event(state)
  end

  defp maybe_finalize(state, _event_id, _cause), do: state

  # -- restore ----------------------------------------------------------------

  # Every restored track is dead: the tracker that owned it died with the
  # previous process for this camera and a fresh one has no state to continue
  # it. That covers the suspended ones too — a suspension is a bet that that
  # process will still be here to adopt it, and this is the branch where it was
  # not. They are ended (`:host_restart`) with their last known summary. New
  # objects can never be confused with them — a ULID is minted once, so a
  # restored event's label ids are never handed out again.
  #
  # Only this camera's slice is read: every camera has its own process and its
  # own row.
  defp restore_from_checkpoint(state) do
    case EventCheckpoint.get(state.camera_id) do
      nil -> state
      {event, tracks} -> restore_event(state, event, tracks)
    end
  end

  defp restore_event(state, event, tracks) do
    Enum.each(tracks, fn track ->
      final = %{track | end_reason: :host_restart}
      Track.broadcast(:track_ended, final)
      # Unconditionally, and with the checkpointed event's id: a checkpoint
      # row exists only while an event is open, so every track restored here
      # was live during that clip — the same rule `record_final/2` applies to
      # an open event. No tier is consulted because none is known here; the
      # camera's policy lives in the config server, and this runs inside
      # `init/1`.
      TrackRecorder.record_final(state.recorder, final, event.id)
    end)

    case Cairn.Registry.whereis(state.camera_id, {:extractor, event.id}) do
      nil ->
        end_orphan(state.camera_id, event)
        state

      # Alive but possibly mid-finalize: the `{:DOWN, _, _, _, :normal}` that
      # follows clears the event silently, which is only correct because
      # `:event_ended` is broadcast *before* the finalize cast (see
      # `maybe_finalize/3`) — the process that died already announced it.
      # Possibly not even alive: the entry may be a corpse the registry has
      # not reaped yet, in which case the monitor answers `:noproc`, which
      # `handle_info/2` treats as the same clean finish.
      pid ->
        Process.monitor(pid)
        # the camera's own policy is unknown here; use the global defaults
        policy = Config.policy(config(), %Config.Camera{id: state.camera_id})
        {post_ref, post_token} = schedule(:post_window, event.id, policy.post)
        {max_ref, max_token} = schedule(:max_event, event.id, policy.max)

        %{
          state
          | event: event,
            extractor: pid,
            post_ref: post_ref,
            post_token: post_token,
            max_ref: max_ref,
            max_token: max_token
        }
    end
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
  #
  # `:finalized` is the only status that means that, and deliberately: an
  # extractor that closed the row `partial` for want of a keyframe
  # (`Cairn.EventExtractor`) and one whose row was left `active` for
  # reconciliation to partial both end where this broadcast is the event's
  # honest status, and consumers dedupe `event_ended` on the id anyway.
  defp end_orphan(camera_id, event) do
    EventCheckpoint.delete(camera_id)

    case indexed_status(event.id) do
      :finalized -> :ok
      _ -> Event.broadcast(:event_ended, %{event | status: :partial, ended_at: now()})
    end
  end

  # This runs inside `init/1` — the only Repo call this process makes before it
  # is alive — and it decides one camera's detections. An unreachable, locked
  # or (in tests) unowned database must not turn into a start failure for the
  # camera whose stream is otherwise fine, so a storage failure degrades to
  # "index says nothing" and the caller announces the event `:partial`.
  # Mislabelling a finalized event that way is recoverable: `event_ended` is
  # at-least-once and consumers dedupe on the event id (see docs/ha-api.md).
  # Only the storage layer's own failures are caught — a bug in here still
  # raises.
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

  defp schedule(kind, event_id, seconds) do
    token = make_ref()
    tref = Process.send_after(self(), {kind, event_id, token}, seconds * 1_000)
    {tref, token}
  end

  defp clear_event(state) do
    if state.post_ref, do: Process.cancel_timer(state.post_ref)
    if state.max_ref, do: Process.cancel_timer(state.max_ref)

    %{
      state
      | event: nil,
        extractor: nil,
        checkpointed_at: nil,
        post_ref: nil,
        post_token: nil,
        max_ref: nil,
        max_token: nil
    }
  end

  defp now, do: DateTime.utc_now()
end
