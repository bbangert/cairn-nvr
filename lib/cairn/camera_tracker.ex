defmodule Cairn.CameraTracker do
  @moduledoc """
  Owns one camera's event lifecycle — one process per camera, one active event.

  Receives tracked batches from the pipeline's detect branch
  (`Cairn.Pipeline.TrackSink` via `Cairn.Detect.Dispatch`): the identities
  `Membrane.MOTTracker` assigned one frame's detections, the lifecycle
  transitions that batch caused, and the checkpoint snapshot taken after them.
  The tracking is the element's; what a batch *means* is this process's. It
  filters by per-label `min_score` and the camera's `record:` tier, and:

    * no active event + evidence -> starts a `Cairn.EventExtractor` and
      broadcasts `{:event_started, event}` on `"events"`
    * evidence during an event -> accumulates time-indexed labels, resets
      the post-window timer, broadcasts `{:event_updated, event}`
    * `post_window` seconds of quiet -> finalizes; `max_event` seconds ->
      finalizes and lets the next piece of evidence open a fresh event

  One process per camera, registered as `Cairn.Registry.via(camera_id,
  :camera_tracker)` and started on demand by `ensure/1` under
  `Cairn.TrackerSupervisor` — deliberately *outside* the per-camera media tree,
  so restarting a camera's ingest does not take its open event with it. The
  tracks themselves do die with a pipeline rebuild, which is where the
  checkpoint below earns its keep: the event finalizes from it either way.
  The process is `:transient`: a crash restarts it and the fresh
  process restores from `Cairn.EventCheckpoint` in `init/1` — so the
  `:host_restart` finals a checkpoint owes go out immediately, not when the
  camera's next observation happens to arrive (a camera whose stream died with
  its tracker would otherwise strand them indefinitely). The clean stop that is
  not restarted is the app shutting down; removing a camera does not stop this
  process — the `:camera_stopped` epoch ends its tracks and the idle tracker
  lingers until shutdown.

  Not every detection is evidence (`evidence?/3`, the one gate both of the
  first two bullets pass through): a predicted ("tracked") object is refused,
  and so is one whose track the tracker element flagged **stationary**. A
  parked car therefore stops resetting the post-window, the event closes on
  schedule and stays closed — nothing reopens it while the car sits there — and the car is
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

  Event times come from the batch rather than from any clock read here:
  `started_at`, `labels[].t` and `trigger.t` derive from its `observed_at`,
  which the engine captured next to the frame and the stamper put in the
  tracking context (`Cairn.Pipeline.ObservationStamper`). The
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
  keeps the last batch of an event; see `forward_boxes/2`.

  A stream boundary suspends the live tracks rather than ending them, so a
  detection in the new stream can adopt an identity the outage interrupted
  instead of minting a second one for the same parked car — but that is the
  tracker element's doing now, and what reaches this process is the finals of
  whatever did not survive it, on the batch that crossed the boundary or on one
  of the element's own when the stream never came back. Turning detection off
  at runtime ends the live set the same way, `:detection_disabled` (the gate is
  `Cairn.Pipeline.ObservationStamper`, which stops feeding the element and tells
  it to let go).

  What the `Cairn.StreamEpochs` subscription is still for is `stale?/2` and the
  end of a stream: an epoch announcement travels from a different process than
  the batches do, so it can arrive while the old session's last batches are
  still crossing the branch, and this is where they are recognised as stale and
  dropped. Only the **detect stream's** announcements: a camera with a
  `substream_url` detects on the sub and records on the main, whose sessions
  boundary independently, and a main-stream reset says nothing about the
  identities the tracker element holds (`detect_role/2`).
  `:camera_stopped` is the one announcement that also ends tracks
  here: the pipeline that held them is going away, and what it emits on its way
  out is not something to wait on — a killed one emits nothing at all — so they
  are ended from the last summaries this process saw. A flushed one *does* emit
  them, afterwards, and `stale?/2` recognises that drain by the epoch the stop
  latched rather than ending everything twice.

  The active event is checkpointed to `Cairn.EventCheckpoint` (ETS owned
  elsewhere, so it survives this process) together with the snapshot the batch
  carried — every track the element still owes a final summary for, live and
  suspended alike: a replacement process re-attaches to a live extractor,
  finalizes an orphan, and ends every restored track (`:host_restart`) —
  broadcasting it and recording it against the checkpointed event, the
  open-event rule above. Writes are throttled to one a second, apart from the
  event's first and last and from the empty snapshot a `:camera_stopped`
  leaves: those finals have gone out already, and a row still naming them
  would have a restart inside the post window end them a second time. How far
  that reaches, and what it does not cover, is `Cairn.Track`'s moduledoc.

  One gap that moduledoc does not cover, because the tracks and this process
  stopped dying together: a **pipeline rebuild** (a crash or the watchdog, not
  a reconnect) takes the tracker element's tracks with it while this process
  lives on, so nobody emits their finals — the checkpoint restore that covers
  this process's own crash does not run, since it did not crash. Their rows are
  closed by `Cairn.Tracks.close_live/0` at the next boot and their event still
  finalizes on its own timers. Bounded by how rare a rebuild is (nothing
  rebuilds per reconnect anymore) and accepted as the price of the tracks
  living in the pipeline.
  """

  use GenServer, restart: :transient

  require Logger

  alias Cairn.{CameraControl, Config, Event, EventCheckpoint, Events, Observation, StreamEpochs}
  alias Cairn.Detect.Dispatch
  alias Cairn.{Track, TrackRecorder}

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
  # labels, or of the track list's last second of churn, costs nothing that the
  # recovery does not already cost. The two transitions that *do* matter for
  # restore are exempt: the first write at event start, and the delete at event
  # end.
  @checkpoint_throttle_ms 1_000

  @doc """
  Starts the tracker for one camera.

  `:camera_id` is required. `:name` defaults to this camera's registered
  via-tuple; `nil` starts it unregistered, which is how a test drives one
  directly. The remaining options (`:start_extractor`, `:finalize_extractor`,
  `:recorder`, `:monotonic_ms`) are injection seams documented at their
  defaults in `init/1`.
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
  supervisor is down (its own restart window). This runs in the camera's
  pipeline, in `Cairn.Pipeline.TrackSink`, and a detect branch must not die
  because the tracker tree is briefly absent — the exit is caught and reported
  as an error instead.
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
  Called by `Cairn.Detect.Dispatch` with one tracked batch
  (`t:Cairn.Detect.Dispatch.batch/0`).

  `policy` is `Cairn.Config.policy/2` for the camera: the event windows, the
  tracking settings and the host-side `track:` / `record:` tiers, resolved at
  pipeline birth so this per-frame path never calls the config server.

  Routes to the camera's own tracker, starting it if this is the first batch.
  """
  @spec tracked(Cairn.Config.Camera.t(), map(), Dispatch.batch()) :: :ok
  def tracked(camera, policy, batch) when is_map(batch) do
    case ensure(camera.id) do
      {:ok, pid} ->
        GenServer.cast(pid, {:tracked, camera, policy, batch})

      {:error, reason} ->
        Logger.debug("camera #{camera.id}: no tracker for this batch (#{inspect(reason)})")
        :ok
    end
  end

  @doc """
  `tracked/3` addressed to an explicit process — the producer's injection seam,
  where a test substitutes itself for the camera's tracker and inspects the
  cast. `nil` means "the camera's own tracker", i.e. `tracked/3`.
  """
  @spec tracked(GenServer.server() | nil, Cairn.Config.Camera.t(), map(), Dispatch.batch()) :: :ok
  def tracked(nil, camera, policy, batch), do: tracked(camera, policy, batch)

  def tracked(server, camera, policy, batch) when is_map(batch),
    do: GenServer.cast(server, {:tracked, camera, policy, batch})

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

    detect_role = detect_role(camera_id, :main)

    state = %{
      camera_id: camera_id,
      event: nil,
      extractor: nil,
      track_updates: %{},
      # Which of this camera's streams the detect branch is fed from, and so
      # the only role whose epochs are this process's business. Re-resolved on
      # every `:started` this camera announces rather than frozen here: this
      # process outlives the camera's pipeline (it sits outside the media
      # tree), and `substream_url` is a restart field, so the role can move
      # under it. See `detect_role/2`.
      detect_role: detect_role,
      current_epoch: seed_epoch(camera_id, detect_role),
      # The epoch that was current when this camera was stopped, held until the
      # next one is adopted: what a dying pipeline still drains is tagged with
      # it, and `apply_epoch/3` has already ended those tracks. See `stale?/2`.
      stopped_epoch: nil,
      # why the current epoch was minted, for the boundary's own report. It
      # comes from the announcement and the counts come from the batch that
      # crossed the boundary, and the announcement is a direct PubSub send
      # while the batch has a decode and an inference call ahead of it — so
      # this is the older of the two by construction, never the newer.
      epoch_reason: nil,
      # the wall instant the last stream reset cut this camera off at, held
      # only until the first batch of the new epoch measures the gap to it
      # (`report_gap/2`)
      gap_from: nil,
      # last seen in `process_batch/4`; see the comment there
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
      monotonic_ms: Keyword.get(opts, :monotonic_ms, &default_monotonic_ms/0)
    }

    {:ok, restore_from_checkpoint(state)}
  end

  # The epoch the detect stream is running under right now, if anything is: it
  # is minted at each session's first buffer, upstream of decode and inference,
  # so it exists before any detection of that session can create this
  # process — reading it here is what lets `stale?/2` judge the very first
  # batch and what makes the next announcement of the same epoch a no-op.
  defp seed_epoch(camera_id, role) do
    case StreamEpochs.current({camera_id, role}) do
      {:ok, epoch} -> epoch
      :unknown -> nil
    end
  end

  # The role the camera's detect branch is built off: `:sub` when it has a
  # substream, `:main` otherwise. A config round trip, which is why it is asked
  # only at init and on this camera's `:started` announcements — a session
  # start is both rare and the one moment the answer can have moved, since a
  # `substream_url` edit restarts the camera tree (`Cairn.Config.Server`'s
  # restart fields) and the pipeline that comes back announces `:started`.
  #
  # Failure mode: the config server serves the *new* config while the *old*
  # pipeline is still running. A `:started` in that window resolves the role
  # the camera is about to have rather than the one it has, and until the
  # restart lands this process ignores the announcements it should follow —
  # `stale?/2` then drops the old pipeline's last batches. The window is the
  # camera restart itself, and a mint needs a fresh RTSP session and its first
  # buffer, so nothing reaches it in practice. A config server that is down or
  # too slow (the call exits) keeps the role already held: degrading to `:main`
  # would silently move a dual-stream camera's tracker onto the recording
  # stream, which is the failure this whole axis exists to prevent.
  defp detect_role(camera_id, held) do
    case Config.Server.camera(camera_id) do
      {:ok, camera} -> Config.Camera.detect_role(camera)
      # A camera the config no longer names (a removal mid-transition) is a
      # lookup failure like any other: keep the role already held rather than
      # silently moving a dual camera's filter onto the recording stream.
      :error -> held
    end
  catch
    :exit, _ -> held
  end

  @impl true
  def handle_cast(
        {:tracked, %{id: camera_id} = camera, policy, batch},
        %{camera_id: camera_id} = state
      ) do
    if stale?(state, batch) do
      {:noreply, state}
    else
      {:noreply, process_batch(state, camera, policy, batch)}
    end
  end

  # A batch addressed to another camera. The producer routes through `ensure/1`
  # on its own camera, so this is a misroute rather than a race — dropped and
  # said out loud, never folded into this camera's event.
  def handle_cast({:tracked, camera, _policy, _batch}, state) do
    Logger.warning(
      "camera #{state.camera_id}: dropped a batch addressed to " <>
        "#{inspect(Map.get(camera, :id))}"
    )

    {:noreply, state}
  end

  # Load-bearing, not belt and braces: the detect branch outlives session
  # boundaries and tags its buffers with the epoch of the frame they came from,
  # so an old-epoch batch drained after a reconnect arrives here truthfully
  # tagged — and this comparison is the only thing that drops it. The
  # announcement it is compared against travels by PubSub while the batch
  # travels down the branch, which is why the two can cross at all.
  #
  # Dropping the batch drops its lifecycle events with it, as it always has —
  # but the tracker element does *not* drop it, and cannot: in the branch's own
  # order it precedes the boundary, so it is the tail of the old session rather
  # than a stray. So an identity minted in the drain window is one this process
  # is never told about, and reaches it later as an `:updated` with no
  # `:started` before it (published as a bare `track_updated`). Bounded by the
  # window — the few batches in flight when the announcement overtook them.
  #
  # A batch with no epoch (replay tooling that sets none) is accepted, as is
  # one for a camera whose epoch is not known here yet: that first batch's
  # epoch is adopted in `process_batch/4`. The one epoch judged against no
  # current one is the stopped camera's, below.
  defp stale?(_state, %{epoch: nil}), do: false

  # The stopped camera's drain, and the other half of `apply_epoch/3`'s
  # `:camera_stopped` clause: the stop is announced *before* the pipeline is
  # flushed, so the EOS that follows reaches the tracker element and its
  # `end_all` emits a second final for every track the announcement already
  # ended — arriving here tagged with the epoch the dying session ran under.
  # Clearing `current_epoch` is what would let them in (a nil epoch judges
  # nothing stale), so the latch is what keeps them out.
  #
  # A batch under a genuinely new epoch is not this: the stream came back, and
  # adopting its epoch in `process_batch/4` releases the latch.
  defp stale?(%{stopped_epoch: epoch} = state, %{epoch: epoch}),
    do: drop(state, epoch, "the stopped camera's drain")

  defp stale?(%{current_epoch: nil}, _batch), do: false
  defp stale?(%{current_epoch: epoch}, %{epoch: epoch}), do: false

  defp stale?(state, %{epoch: epoch}), do: drop(state, epoch, "a stale epoch")

  defp drop(state, epoch, why) do
    # Rare by construction, so it is counted rather than logged per line: a
    # boundary drains at most a burst of old-epoch frames, so a steady rate
    # here means something upstream is mis-tagging.
    #
    # The event name is `:aggregator` for a wire-compatibility reason and not
    # an accidental one: it is what dashboards and alerts already match on,
    # and renaming it would silently blind them.
    :telemetry.execute([:cairn, :aggregator, :stale_observation], %{count: 1}, %{
      camera_id: state.camera_id
    })

    Logger.debug("camera #{state.camera_id}: dropped batch from #{why} (#{epoch})")
    true
  end

  defp process_batch(state, camera, policy, batch) do
    state =
      %{
        state
        | current_epoch: state.current_epoch || batch.epoch,
          # This batch is not the drain of whatever was stopped — `stale?/2`
          # dropped that — so the camera is streaming again and the latch has
          # nothing left to recognise.
          stopped_epoch: nil,
          # Cached for the track rows, and set before the events of this batch
          # are published so a track ending in it is gated on this batch's
          # policy. The ended-track paths that need them — `apply_epoch/3` and
          # checkpoint restore — are handed neither a camera nor a policy, and
          # reaching for the config server there would put a call on a path an
          # epoch broadcast drives.
          policy: policy,
          camera: camera
      }
      |> report_link(batch)
      |> publish_tracks(batch.events)

    # A predicted ("tracked") object, a track the tracker keeps predicting long
    # after anything last detected it, and a track that has held still past the
    # camera's `stationary_after_ms` are all not evidence: they keep the
    # tracker warm but can neither open an event nor hold one open. Nor is a
    # detection the camera's `record:` tier does not admit.
    #
    # The floor is the batch's own — the effective one the tracker partitioned
    # it against, runtime override included (see
    # `Cairn.Pipeline.ObservationStamper`). Reading the override again here
    # would be a second read of a mutable table, and a box that may earn video
    # but may not mint the track carrying it is an event with no identity
    # behind it.
    #
    # `Map.get/2` for the record tier: `tracked/3` is a public entry point any
    # caller can hand a bare map, and a missing key has to read as an absent
    # block rather than raise on this path.
    # The `||` is for the batches that carry no context — the element's own,
    # which have no tagged objects either, so it decides nothing and exists so
    # that a caller handing one by hand cannot put a nil in the comparison.
    min_score = batch.min_score || camera.min_score
    passing = Enum.filter(batch.tagged, &evidence?(&1, min_score, Map.get(policy, :record)))

    state =
      cond do
        # No evidence, but the batch still moved the tracker: a live track
        # ended, one below the tier started. An open event's checkpoint has to
        # follow that too, or a crash inside the post window restores finals
        # for tracks that already ended and none for the ones still live.
        passing == [] -> checkpoint(state, batch.snapshot)
        # recording disabled: evaluate detections but don't open a new event
        state.event == nil and not recording_enabled?(state) -> state
        state.event == nil -> start_event(state, camera, policy, batch, passing)
        true -> update_event(state, policy, batch, passing)
      end

    # After the lifecycle `cond` and on its result, deliberately: the batch
    # that opens an event is part of that event's path (at `t_ms` 0), and
    # before the `cond` `state.event` would still be nil for it.
    forward_boxes(state, batch)

    state
  end

  # The one runtime control left on this path: detection being off is the
  # stamper's gate, upstream, so a batch that got here was produced under a
  # camera whose detection is on.
  defp recording_enabled?(state), do: CameraControl.get(state.camera_id).recording_enabled

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
  # The other gap is upstream: a box the tracker refused and suppressed as a
  # duplicate never reaches `tagged` at all, and cannot, because it has no
  # `object_id` to draw it under. That is the trade `Cairn.Tracker` makes on
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
  #
  # The element's own buffers carry no `observed_at` and no boxes, so there is
  # nothing to draw and nothing to date it by; they fall through the clause
  # below.
  defp forward_boxes(
         %{event: %Event{} = event, extractor: pid},
         %{observed_at: %DateTime{} = observed_at, tagged: tagged}
       )
       when is_pid(pid) do
    GenServer.cast(
      pid,
      {:track_boxes,
       %{
         t_ms: DateTime.diff(observed_at, event.started_at, :millisecond),
         boxes: Enum.map(tagged, &{&1.object_id, &1.label, &1.bbox, &1.stationary})
       }}
    )
  end

  defp forward_boxes(_state, _batch), do: :ok

  # The single gate: the objects this accepts are `passing`, which is what both
  # `start_event/5` and `update_event/4` are handed, so what is refused here
  # can neither open an event nor hold one open. That pairing is the whole
  # point of the stationary rule — a parked car keeps producing detections, and
  # refusing them is what lets the post-window run out instead of being reset
  # by every frame of a car that is going nowhere.
  #
  # `object.stationary` is read directly rather than defaulted: every object
  # this is called with came out of a tracker core's `track/3`, whose contract
  # with this host is that it tags `object_id`, `stale_predicted` and
  # `stationary` onto every object it returns.
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

  # What a new epoch does to the tracks is the tracker element's business now
  # (it suspends them in-band, on the buffer that crossed the boundary). What
  # is left here is the bookkeeping `stale?/2` reads: an announcement travels
  # by PubSub while the batches travel down the branch, so one can arrive with
  # the old session's last batches still in flight, and holding the current
  # epoch here is what lets those be recognised and dropped.
  #
  # An epoch older than the one already held is ignored (see
  # `Cairn.ULID.superseded?/2`): applying it would roll `current_epoch` back to
  # a stream nothing decodes under, and `stale?/2` would then drop every batch
  # the branch still forwards — a silent, sustained outage for this camera
  # until its next mint.
  #
  # The topic carries every camera's mints, and both roles of each; only this
  # camera's detect stream is ours. A dual-stream camera's main reset is not a
  # boundary here — the tracker element's identities came off the sub stream
  # and nothing about them changed — so it must not become `current_epoch`,
  # which would have `stale?/2` drop every sub-tagged batch that follows.
  #
  # The role is re-resolved before the comparison, not after: a `:started` is
  # the first word of a pipeline that may have been rebuilt around a
  # `substream_url` edit, and judging it against the role that edit replaced
  # would ignore the only announcement that could release the stale gate.
  def handle_info(
        {:stream_epoch, camera_id, role, epoch, reason},
        %{camera_id: camera_id} = state
      ) do
    state = resolve_role(state, reason)

    cond do
      role != state.detect_role -> {:noreply, state}
      Cairn.ULID.superseded?(state.current_epoch, epoch) -> {:noreply, state}
      true -> {:noreply, apply_epoch(state, epoch, reason)}
    end
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

  # Deliberately not on `:camera_stopped`: a stop is minted per role by the
  # pipeline that is going away, so it has to be judged against the role that
  # pipeline ran under. Re-reading a config that has already moved would have
  # this process ignore its own camera's stop and keep tracks nothing will ever
  # end.
  defp resolve_role(state, :started),
    do: %{state | detect_role: detect_role(state.camera_id, state.detect_role)}

  defp resolve_role(state, _reason), do: state

  # `:camera_stopped` names the end of a stream, not the start of one: nothing
  # will ever decode under that epoch. It ends every track this process still
  # has a summary for — the pipeline that held them is being torn down, so no
  # batch is coming that could carry their finals, and nothing is coming that
  # could adopt them either — but the epoch must never become `current_epoch`.
  # The stop
  # and the start of one camera are announced by different processes, and on the
  # degraded caller-side broadcast path they have no ordering relation, so a
  # stop epoch minted after a live `:started` could otherwise be adopted as
  # current and `stale?/2` would then drop every observation of a *healthy*
  # camera until its next session boundary — which is not coming.
  #
  # `current_epoch` is cleared rather than kept: this camera is not streaming
  # under anything, so there is no epoch a straggling observation could be
  # judged against, and holding the dead one would drop the first batch of a
  # stream that came back before its mint was announced. The next mint seeds it
  # again.
  #
  # What it is moved to rather than dropped is the other half of that: the
  # tracks ended here are ended again by the pipeline being torn down behind
  # this announcement (`Cairn.PipelineOwner` broadcasts, then flushes; the EOS
  # reaches `Membrane.MOTTracker` and its `end_all` finals arrive as an
  # ordinary batch), and with `current_epoch` nil there is nothing left to
  # recognise them by. `stale?/2` reads the latch; a fresh epoch releases it.
  # The old value survives a repeated announcement, which would otherwise
  # overwrite the latch with the `current_epoch` the first one emptied.
  defp apply_epoch(state, _epoch, :camera_stopped) do
    ended =
      for {_id, %{track: %Track{} = track}} <- state.track_updates,
          do: {:ended, %{track | end_reason: :stream_reset}}

    state = %{
      state
      | current_epoch: nil,
        stopped_epoch: state.current_epoch || state.stopped_epoch,
        gap_from: nil
    }

    state = publish_tracks(state, ended)

    # The finals above are the last word on those identities, and an open
    # event's checkpoint has to say so: a restart inside the post window
    # restores the row, and a row still naming them ends them a second time as
    # `:host_restart`. No batch is coming to correct it — the pipeline behind
    # this announcement is being torn down — so the throttle is bypassed: this
    # is a lifecycle transition, not a frame.
    if state.event, do: write_checkpoint(state, []), else: state
  end

  # One mint can be announced twice by design: `Cairn.StreamEpochs` broadcasts
  # from the caller when its server is unreachable, and a call that exited with
  # :timeout may still be served afterwards. The epoch is the same either way,
  # so a repeat means no boundary was crossed. The repeat is caught even for the
  # mint that predates this process: `init/1` seeds `current_epoch` from the
  # epoch table.
  defp apply_epoch(%{current_epoch: epoch} = state, epoch, _reason), do: state

  defp apply_epoch(state, epoch, reason),
    do: %{state | current_epoch: epoch, epoch_reason: reason, stopped_epoch: nil}

  # -- link health ------------------------------------------------------------

  # What the boundary did, reported from the batch that carried it across:
  # the tracker element suspends in-band, so the counts arrive with the first
  # batch of the new session rather than with the announcement of it.
  defp report_suspension(state, %{suspension: nil}), do: state

  defp report_suspension(state, %{suspension: suspension}) do
    Logger.info(
      "camera #{state.camera_id}: stream reset (#{state.epoch_reason}) — " <>
        "#{suspension.suspended} track(s) suspended for adoption, #{suspension.ended} ended"
    )

    :telemetry.execute(
      [:cairn, :tracker, :stream_reset],
      %{suspended: suspension.suspended, ended: suspension.ended},
      %{camera_id: state.camera_id, reason: state.epoch_reason}
    )

    %{state | gap_from: suspension.at}
  end

  # How the stream reset actually went, reported from the first batch that
  # follows it: the outage gap can only be measured once the far side produces
  # an observation to measure to. `gap_from` is the last observation before the
  # cut, and it is cleared here so the report is one line per reset and not one
  # per batch. The batch that crosses the boundary carries both — the
  # suspension that sets `gap_from` and the observation that measures to it —
  # so the order below is what makes that batch report a gap of its own outage
  # rather than of the previous one.
  #
  # Adoptions and lapses are counted off the same batch's events, which is
  # where the tracker reports them: an adoption is a track resuming its
  # identity, and a `:stream_reset` end is a suspension whose window ran out
  # (on this batch, or on one of the element's own).
  defp report_link(state, batch) do
    report_adopted(state.camera_id, batch.events)
    report_expired(state.camera_id, batch.events)

    state |> report_suspension(batch) |> report_gap(batch)
  end

  defp report_gap(%{gap_from: nil} = state, _batch), do: state
  defp report_gap(state, %{observed_at: nil}), do: state

  defp report_gap(state, %{observed_at: observed_at}) do
    gap = max(DateTime.diff(observed_at, state.gap_from, :millisecond), 0)

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
  # track today has been through `process_batch/4`, which caches both. A
  # tracker that has never received a batch does exist — `ensure/1` is public
  # and `restore_checkpointed/0` starts one per checkpointed camera — but it
  # knows no tracks, so none reaches here and the nil caches are never read. An
  # end path that ever skips it must not silently exclude the track, so an
  # absent policy is read as an absent `track:` block, i.e. the label's wire
  # floor off a default camera.
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
  #
  # `track` is the last summary that went out for it, which is what a final has
  # to be built from on the one path that gets no event of its own: a camera
  # stopping (`apply_epoch/3`). The tracks are the tracker element's, and it is
  # going away with the pipeline.
  defp note_update(state, track) do
    rowed? = record_live(state, track)

    entry = %{
      at: state.monotonic_ms.(),
      best_score: track.best_score,
      rowed?: rowed?,
      track: track
    }

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

  defp start_event(state, camera, policy, batch, dets) do
    observed_at = batch.observed_at

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
        EventCheckpoint.put(camera.id, event, batch.snapshot)
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

  defp update_event(%{event: event} = state, policy, batch, dets) do
    max_scores = max_scores(event.max_scores, dets)
    observed_at = batch.observed_at

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
    state = checkpoint(%{state | event: event}, batch.snapshot)
    Event.broadcast(:event_updated, event)

    {post_ref, post_token} = schedule(:post_window, event.id, policy.post)
    %{state | post_ref: post_ref, post_token: post_token}
  end

  # The snapshot is the batch's, taken by the tracker element after it: this
  # process holds no tracker to derive one from, and the one that came with the
  # batch is what that batch's event was open over.
  #
  # Nothing to checkpoint with no event open: the row exists only for the life
  # of one, and every batch that arrives outside one reaches here.
  defp checkpoint(%{event: nil} = state, _snapshot), do: state

  defp checkpoint(state, snapshot) do
    now = state.monotonic_ms.()

    if state.checkpointed_at == nil or now - state.checkpointed_at >= @checkpoint_throttle_ms do
      write_checkpoint(state, snapshot)
    else
      state
    end
  end

  defp write_checkpoint(%{event: event} = state, snapshot) do
    EventCheckpoint.put(event.camera_id, event, snapshot)
    %{state | checkpointed_at: state.monotonic_ms.()}
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
    # process already sent (`forward_boxes/2`) ahead of it in the same
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
