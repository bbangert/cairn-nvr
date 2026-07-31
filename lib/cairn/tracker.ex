defmodule Cairn.Tracker do
  @moduledoc """
  Pure per-camera object tracker: turns a stream of observations into tracks
  with public `Cairn.ULID` identities and a started/updated/ended lifecycle.

  Identity is assigned in one of two modes, decided per object:

    * **host mode** — greedy-IoU matching against the live host tracks of the
      same label. This is the only mode for a plugin that does not track.
    * **plugin mode** — the observation comes from a plugin that declared the
      `object_tracking` capability (`observation.tracking`) *and* the object
      carries a `track_id`. The plugin's id maps 1:1 onto a ULID for the life
      of `(plugin_instance, epoch, track_id)`; no IoU runs, and
      `observation.ended_tracks` ends those tracks. A `track_id` reused after
      it appeared in `ended_tracks` is a contract violation: it is logged and
      treated as a new track (new ULID).

  A `track_id` from a plugin that did **not** declare `object_tracking` is
  ignored — the object is tracked host-side. Capability is the plugin's
  promise that its ids are stable; without it they are decoration.

  Expiry is media time, not batches: a track is ended (`:unseen`) once
  `media_ms - last_seen_ms > max_unseen_ms`. `last_seen_ms` moves on *any*
  observation of the track, predicted ones included — slow inference must not
  kill a track. Evidence policy is separate: a track whose last **detection**
  is older than `max_unseen_ms` is flagged `stale_predicted`, and the
  aggregator refuses it as event evidence however long the plugin keeps
  predicting it.

  A track the tracker has judged **stationary** (see below) expires at
  `@stationary_unseen_factor` times that bound instead, and for as long as it
  sits inside that extended grace — already unseen for longer than
  `max_unseen_ms` — nothing may re-match it at less than
  `@stationary_match_iou` overlap. The patience is paid for with pickiness: a
  parked object survives an occlusion that would end a moving track, and its
  identity still cannot be handed to whatever next overlaps it. Outside the
  grace a stationary track matches at the same `@iou_threshold` as everything
  else.

  What the grace does not require is *detections*: `last_seen_ms` moves on
  predicted observations too and the stillness rule ignores them, so a plugin
  that keeps predicting a box at the parked position holds the identity and
  the stationary flag for as long as it predicts, no matter how long that is.
  That is the "slow inference must not kill a track" contract above, over a
  window the grace makes longer; `stale_predicted` is what keeps it from
  counting as evidence.

  Media time may jump backwards (a new ffmpeg run restarts the RTP timeline).
  Within an epoch that only makes the elapsed time negative, which never
  expires anything; across epochs the aggregator ends every track and starts
  a fresh tracker.

  ## Host policy: the live set is bounded, on both counts

  `media_ms` is the plugin's own `pts`, so media-time expiry alone leaves the
  plugin holding the clock that retires its tracks. Two host-side bounds close
  that, and both belong here rather than in the codec because they are about
  accumulated state, not about one line:

    * **A cap on live tracks** (`max_live_tracks`, per camera). At the cap,
      minting a new identity retires the least recently seen live track with a
      final summary (`:evicted`). Tracks that this batch already assigned are
      never the victim.
    * **A host-clock backstop.** A track whose age on the *host's* monotonic
      clock (`now_ms`, supplied by the caller) exceeds ten times its effective
      unseen bound — `max_unseen_ms`, or the grace-extended bound above for a
      stationary track — is expired (`:unseen`) whatever media time says, so a
      frozen or rewound `pts` cannot pin tracks alive. It scales off the same
      bound as the media-time rule on purpose: left at the plain one it would
      retire a stationary track at exactly the bound the grace exists to
      extend, cancelling the grace without a trace of why. The factor is
      deliberately lax: media time is the real rule, and this must never fire
      for a stream that is merely slow.

  ## Stationary detection

  A track is stationary once its box has held still for the camera's
  `stationary_after_ms` of media time. "Still" is measured against an
  **anchor** — the box the object was last seen to move to — not against the
  previous box: comparing consecutive boxes calls a slow walk motionless,
  because every step is within jitter of the one before it. The anchor is
  reset only when the object moves, so it answers "has it moved since it last
  moved" however long the track lives.

  The current box is the per-coordinate median of the last few **detected**
  boxes rather than the newest one, so a single mis-sized box cannot flip a
  motionless object into motion, nor a moving one out of it.

  Every stationary update is gated on `Cairn.Observation.detected?/1`, for the
  same reason as `stale_predicted`: a predicted box repeats the plugin's own
  extrapolation, so counting it would manufacture stillness out of the
  plugin's guesses. Predicted observations leave the anchor and every
  stationary field untouched.

  Two things this cannot see, both because the host has boxes and not pixels:

    * **Camera motion.** A PTZ move or a knocked mount shifts every box in the
      frame, so every stationary track starts moving together as the median
      follows the new view, and every one of them settles again a threshold
      after it stops. There is no motion compensation here — the host has no
      view geometry to compensate with.
    * **Motion inside a still box.** Someone standing in place and gesturing,
      or a car idling, keeps a motionless box and reads as stationary. The
      metric is the box, not what is happening inside it.

  The flag is not only reported: expiry keys off it, so anything that reads as
  stationary — either blind spot included — also gets the longer unseen bound
  and the strict re-match threshold that comes with it, and
  `Cairn.DetectionAggregator` refuses it as event evidence for as long as it
  is set.

  Bboxes are `[x, y, w, h]` in any consistent unit (normalized or pixels).
  """

  require Logger

  alias Cairn.Observation
  alias Cairn.Track
  alias Cairn.ULID

  @iou_threshold 0.1
  # What a stationary track in extended grace demands of a box before it will
  # answer to it. The two thresholds are a pair and neither works alone:
  # applied to a track that is still being seen, this one rejects ordinary
  # detector jitter, the match fails, and the object gets a second, duplicate
  # track. Applied only where it belongs — a track already unseen past
  # `max_unseen_ms`, where every overlapping box is a candidate to inherit an
  # identity nothing is currently confirming — it is what makes the grace safe.
  # Getting that pairing wrong is a silent identity bug, which is why neither
  # number is config.
  @stationary_match_iou 0.7
  # The unseen bound for a stationary track, as a multiplier of
  # `max_unseen_ms` (the `@host_clock_factor` precedent: policy the operator
  # sets the base for, scaled here by a fixed factor). A parked object is
  # occluded for as long as whatever parked in front of it stays, which is not
  # the timescale a moving track needs; the patience is paid for with
  # `@stationary_match_iou`.
  @stationary_unseen_factor 5
  # Overlap between the anchor and the smoothed current box that still counts
  # as "has not moved". Not config, on the same rule as `@iou_threshold`: an
  # operator looking at a camera view cannot reason about an IoU number, and
  # the knob that answers the question they actually have — "how long before
  # you call it parked" — is `stationary_after_ms`.
  @stationary_iou 0.8
  # Detected boxes kept for the per-coordinate median. Odd, so a full window's
  # median is a value the detector actually reported on each axis (a warming-up
  # window can be even and average two); short, so a real move reaches the
  # smoothed box within a handful of detections at any frame rate.
  @recent_boxes 5
  # Plugin track ids that have been ended, kept so their reuse can be caught.
  # Only live tracks bound the rest of the state; this set is bounded here.
  @max_ended_keys 4_096
  # How much slower than media time the host clock is allowed to be before a
  # track is expired regardless. See the moduledoc: a backstop, not the rule.
  @host_clock_factor 10
  # Every warning here is driven by plugin output, and plugin output is a
  # per-line primitive: unrate-limited they are a log-flood of their own.
  @warn_interval_ms 5_000

  defstruct objects: %{}, index: %{}, ended: %{}, ended_seq: 0, warned_at: %{}

  @type bbox :: [number()]
  @type t :: %__MODULE__{}

  @typedoc "Everything about the observation the tracker needs, and nothing else."
  @type context :: %{
          camera_id: String.t() | nil,
          epoch: String.t() | nil,
          plugin_instance: String.t() | nil,
          media_ms: number(),
          observed_at: DateTime.t() | nil,
          tracking: boolean(),
          ended_tracks: [String.t()],
          max_unseen_ms: pos_integer(),
          max_live_tracks: pos_integer(),
          stationary_after_ms: pos_integer(),
          now_ms: number()
        }

  @typedoc "The host-side tracking policy for one camera."
  @type policy :: %{
          max_unseen_ms: pos_integer(),
          max_live_tracks: pos_integer(),
          stationary_after_ms: pos_integer()
        }

  @type event ::
          {:started | :updated | :ended, Track.t()}
          | {:became_stationary | :started_moving, Track.t()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Builds the tracking context for one observation.

  `camera_id` is the caller's — the aggregator keys its state by the
  *configured* camera, and that is what a track summary must name, whatever
  the plugin put on the wire.

  `now_ms` is the host's monotonic clock, injected rather than read here so
  the tracker stays pure and the host-clock backstop is testable without
  sleeping.
  """
  @spec context(Observation.t(), String.t(), policy(), number()) :: context()
  def context(%Observation{} = observation, camera_id, policy, now_ms) do
    %{
      camera_id: camera_id,
      epoch: observation.epoch,
      plugin_instance: observation.plugin_instance,
      media_ms: observation.media_ms,
      observed_at: observation.observed_at,
      tracking: observation.tracking,
      ended_tracks: observation.ended_tracks,
      max_unseen_ms: policy.max_unseen_ms,
      max_live_tracks: policy.max_live_tracks,
      stationary_after_ms: policy.stationary_after_ms,
      now_ms: now_ms
    }
  end

  @doc """
  Folds one observation's objects into the tracker.

  Returns `{tracker, tagged_objects, events}`: every object tagged with its
  `object_id` (ULID) and its track's `stale_predicted` and `stationary` flags,
  in the order given, and the lifecycle events this observation caused.

  An object the tracker refuses — a `track_id` repeated inside this batch, or
  a new identity at the live-track cap with nothing evictable — is absent from
  the tagged list, so `tagged` may be shorter than `objects`.

  Staleness is refreshed *before* expiry so that an expiring track's final
  summary reports this batch's `stale_predicted`, not the previous batch's.
  """
  @spec track(t(), [map()], context()) :: {t(), [map()], [event()]}
  def track(%__MODULE__{} = tracker, objects, context) do
    {tracker, ended} = end_plugin_tracks(tracker, context)
    {tracker, assignments} = assign(tracker, objects, context)
    {tracker, tagged, lifecycle} = apply_assignments(tracker, objects, assignments, context)
    {tracker, expired} = tracker |> refresh_stale(context) |> expire(context)

    {tracker, tagged, ended ++ lifecycle ++ expired}
  end

  @doc """
  Ends every live track with `reason` and returns an emptied tracker.

  Used at a stream-epoch boundary: no track may span the cut, and every track
  owes its consumers a final summary.

  `keep_ended: true` carries the plugin ids already declared ended over to the
  new tracker, so their reuse is still reported as the contract violation it
  is. Which of the two is right follows from the identity key: an epoch cut
  changes `epoch`, so a stale ended entry can never match again and is dropped
  with the rest of the state. A cut *inside* an epoch (detection toggled off
  and back on) leaves the key untouched — drop the memory there and a plugin
  reusing an id it ended is silently given a fresh identity instead.
  """
  @spec end_all(t(), Track.end_reason(), keyword()) :: {t(), [event()]}
  def end_all(%__MODULE__{} = tracker, reason, opts \\ []) do
    emptied =
      if Keyword.get(opts, :keep_ended, false),
        do: %__MODULE__{ended: tracker.ended, ended_seq: tracker.ended_seq},
        else: new()

    {emptied, for({_id, object} <- tracker.objects, do: {:ended, to_track(object, reason)})}
  end

  @doc "Summaries of the currently live tracks (ULID order, so mint order)."
  @spec live_tracks(t()) :: [Track.t()]
  def live_tracks(%__MODULE__{} = tracker) do
    # Sorted explicitly: map iteration order is only incidentally sorted while
    # `objects` is a small (flat) map, and checkpointed track lists must not
    # reshuffle once a busy scene pushes it past that boundary.
    tracker.objects
    |> Enum.sort_by(fn {id, _object} -> id end)
    |> Enum.map(fn {_id, object} -> to_track(object) end)
  end

  @doc "Intersection-over-union of two `[x, y, w, h]` boxes."
  @spec iou(bbox(), bbox()) :: float()
  def iou([ax, ay, aw, ah], [bx, by, bw, bh]) do
    ix = max(ax, bx)
    iy = max(ay, by)
    ix2 = min(ax + aw, bx + bw)
    iy2 = min(ay + ah, by + bh)

    inter = max(ix2 - ix, 0) * max(iy2 - iy, 0)
    union = aw * ah + bw * bh - inter

    if union <= 0, do: 0.0, else: inter / union
  end

  # -- plugin-declared ends ---------------------------------------------------

  defp end_plugin_tracks(tracker, %{tracking: true, ended_tracks: [_ | _] = ids} = context) do
    Enum.reduce(ids, {tracker, []}, fn id, {tracker, events} ->
      key = plugin_key(id, context)
      tracker = remember_ended(tracker, key)

      case Map.fetch(tracker.index, key) do
        {:ok, object_id} ->
          {object, objects} = Map.pop(tracker.objects, object_id)
          tracker = %{tracker | objects: objects, index: Map.delete(tracker.index, key)}
          {tracker, events ++ ended_event(object, :plugin_ended)}

        :error ->
          {tracker, events}
      end
    end)
  end

  defp end_plugin_tracks(tracker, _context), do: {tracker, []}

  defp ended_event(nil, _reason), do: []
  defp ended_event(object, reason), do: [{:ended, to_track(object, reason)}]

  # -- assignment -------------------------------------------------------------

  # `%{object index => object_id | :drop}`; an index with no entry is a new
  # track, `:drop` an object the tracker refuses.
  defp assign(tracker, objects, context) do
    {plugin, host} =
      objects
      |> Enum.with_index()
      |> Enum.split_with(fn {object, _index} -> plugin_tracked?(object, context) end)

    {tracker, plugin_assignments} = assign_plugin(tracker, plugin, context)
    {tracker, Map.merge(plugin_assignments, assign_host(tracker, host, context))}
  end

  # One `track_id` names one object. Two objects in the same batch claiming the
  # same id would otherwise share a ULID — one `:started` and one `:updated`
  # for the same identity, with the second box overwriting the first — so the
  # first occurrence wins and the rest are refused. Same class of contract
  # violation as reuse-after-`ended_tracks`, treated the same way.
  defp assign_plugin(tracker, indexed, context) do
    {tracker, assignments, _seen} =
      Enum.reduce(indexed, {tracker, %{}, MapSet.new()}, fn {object, index},
                                                            {tracker, assignments, seen} ->
        key = plugin_key(object.track_id, context)

        if MapSet.member?(seen, key) do
          {warn_duplicate(tracker, object, context), Map.put(assignments, index, :drop), seen}
        else
          {tracker, object_id} = plugin_identity(tracker, key, object, context)
          {tracker, Map.put(assignments, index, object_id), MapSet.put(seen, key)}
        end
      end)

    {tracker, assignments}
  end

  defp warn_duplicate(tracker, object, context) do
    warn_once(
      tracker,
      context,
      :duplicate_track_id,
      "camera #{context.camera_id}: plugin #{inspect(context.plugin_instance)} sent track id " <>
        "#{inspect(object.track_id)} twice in one batch — dropping the duplicate object"
    )
  end

  defp warn_reuse(tracker, object, context) do
    warn_once(
      tracker,
      context,
      :reused_track_id,
      "camera #{context.camera_id}: plugin #{inspect(context.plugin_instance)} reused " <>
        "track id #{inspect(object.track_id)} after ending it — tracking it as a new object"
    )
  end

  defp plugin_identity(tracker, key, object, context) do
    if Map.has_key?(tracker.ended, key) do
      tracker = warn_reuse(tracker, object, context)
      object_id = ULID.generate()
      {tracker |> forget_ended(key) |> bind(key, object_id), object_id}
    else
      case Map.fetch(tracker.index, key) do
        {:ok, object_id} ->
          {tracker, object_id}

        :error ->
          object_id = ULID.generate()
          {bind(tracker, key, object_id), object_id}
      end
    end
  end

  # Greedy IoU, best overlap first, each object and each track used once. Only
  # host-owned tracks are candidates: a plugin's identities are its own. The
  # threshold is per candidate track (`match_threshold/2`), so it decides which
  # pairs exist and never how the ones that exist are ordered.
  defp assign_host(tracker, indexed, context) do
    candidates = for {id, object} <- tracker.objects, object.source == :host, do: {id, object}

    pairs =
      for {object, index} <- indexed,
          {id, tracked} <- candidates,
          tracked.label == object.label,
          overlap = iou(tracked.bbox, object.bbox),
          overlap >= match_threshold(tracked, context) do
        {overlap, index, id}
      end

    # A total sort key, not just `-overlap`: `pairs` is built by comprehension
    # over a map, whose iteration order is unsorted past 32 keys, and a stable
    # sort would then resolve two identically-overlapping candidates by that
    # incidental order. `index` before `id` keeps "earlier object in the batch
    # wins", matching the incumbent-wins convention elsewhere.
    {assignments, _used_objects, _used_tracks} =
      pairs
      |> Enum.sort_by(fn {overlap, index, id} -> {-overlap, index, id} end)
      |> Enum.reduce({%{}, MapSet.new(), MapSet.new()}, fn {_overlap, index, id},
                                                           {assignments, objects, tracks} ->
        if MapSet.member?(objects, index) or MapSet.member?(tracks, id) do
          {assignments, objects, tracks}
        else
          {Map.put(assignments, index, id), MapSet.put(objects, index), MapSet.put(tracks, id)}
        end
      end)

    assignments
  end

  # Strict only while a stationary track is in extended grace — already unseen
  # past `max_unseen_ms`, so nothing is currently confirming the identity an
  # overlapping box would inherit. A track being seen normally matches at the
  # base threshold, and must: see `@stationary_match_iou` for what dropping
  # that distinction costs.
  defp match_threshold(%{stationary: true} = tracked, context) do
    if context.media_ms - tracked.last_seen_ms > context.max_unseen_ms,
      do: @stationary_match_iou,
      else: @iou_threshold
  end

  defp match_threshold(_tracked, _context), do: @iou_threshold

  defp apply_assignments(tracker, objects, assignments, context) do
    # Tracks this batch already spoke for: retiring one to make room for a new
    # identity would churn the very tracks the cap exists to protect.
    protected = for {_index, id} <- assignments, is_binary(id), into: MapSet.new(), do: id

    {tracker, tagged, events} =
      objects
      |> Enum.with_index()
      |> Enum.reduce({tracker, [], []}, fn {object, index}, acc ->
        apply_object(acc, object, Map.get(assignments, index, :new), protected, context)
      end)

    {tracker, Enum.reverse(tagged), Enum.reverse(events)}
  end

  defp apply_object(acc, _object, :drop, _protected, _context), do: acc

  defp apply_object({tracker, tagged, events}, object, assigned, protected, context) do
    case fetch_assigned(tracker, assigned) do
      {:ok, object_id, existing} ->
        tracked = update_track(existing, object, context)
        summary = to_track(tracked)

        {store(tracker, object_id, tracked), [tag(object, object_id, tracked) | tagged],
         transition(existing, tracked, summary) ++ [{:updated, summary} | events]}

      :error ->
        case make_room(tracker, protected, context) do
          {:ok, tracker, evicted} ->
            object_id = new_object_id(assigned)
            tracked = new_track(object_id, object, context)

            {store(tracker, object_id, tracked), [tag(object, object_id, tracked) | tagged],
             [{:started, to_track(tracked)} | Enum.reverse(evicted) ++ events]}

          {:full, tracker} ->
            {tracker, tagged, events}
        end
    end
  end

  defp fetch_assigned(_tracker, :new), do: :error

  defp fetch_assigned(tracker, object_id) do
    case Map.fetch(tracker.objects, object_id) do
      {:ok, existing} -> {:ok, object_id, existing}
      :error -> :error
    end
  end

  defp new_object_id(:new), do: ULID.generate()
  defp new_object_id(object_id), do: object_id

  defp store(tracker, object_id, tracked),
    do: %{tracker | objects: Map.put(tracker.objects, object_id, tracked)}

  # The transition follows its own `:updated` in the event list: that summary
  # carries the stationary fields the flip is about, so a consumer that folds
  # events in order has them before it is told the edge happened.
  defp transition(%{stationary: was}, %{stationary: was}, _summary), do: []
  defp transition(_existing, %{stationary: true}, summary), do: [{:became_stationary, summary}]
  defp transition(_existing, %{stationary: false}, summary), do: [{:started_moving, summary}]

  defp tag(object, object_id, tracked) do
    Map.merge(object, %{
      object_id: object_id,
      stale_predicted: tracked.stale_predicted,
      stationary: tracked.stationary
    })
  end

  # -- the live-track cap -----------------------------------------------------

  defp make_room(tracker, protected, context) do
    if map_size(tracker.objects) < context.max_live_tracks do
      {:ok, tracker, []}
    else
      evict_oldest(tracker, protected, context)
    end
  end

  defp evict_oldest(tracker, protected, context) do
    candidates =
      for {id, object} <- tracker.objects, not MapSet.member?(protected, id), do: {id, object}

    case candidates do
      [] ->
        {:full,
         warn_cap(tracker, context, "every live track is in this batch — dropping the new object")}

      _ ->
        # `{last_seen_ms, id}` rather than `last_seen_ms` alone: ties must not
        # be broken by map iteration order.
        #
        # LRU on `last_seen_ms` already prefers a track nothing is detecting
        # any more — one riding out its grace included — over the ones this
        # scene is actively seeing, which is the preference the cap wants:
        # extended grace buys time against expiry, not against a full live set,
        # and is deliberately not exempted here.
        {id, object} = Enum.min_by(candidates, fn {id, o} -> {o.last_seen_ms, id} end)
        tracker = warn_cap(tracker, context, "evicting the least recently seen track #{id}")

        {:ok, remove_object(tracker, id), [{:ended, to_track(object, :evicted)}]}
    end
  end

  defp warn_cap(tracker, context, detail) do
    warn_once(
      tracker,
      context,
      :track_cap,
      "camera #{context.camera_id}: at the #{context.max_live_tracks} live-track cap — #{detail}"
    )
  end

  defp remove_object(tracker, object_id) do
    index = for {key, id} <- tracker.index, id != object_id, into: %{}, do: {key, id}
    %{tracker | objects: Map.delete(tracker.objects, object_id), index: index}
  end

  defp warn_once(tracker, context, class, message) do
    last = Map.get(tracker.warned_at, class)

    if is_nil(last) or context.now_ms - last >= @warn_interval_ms do
      Logger.warning(message)
      %{tracker | warned_at: Map.put(tracker.warned_at, class, context.now_ms)}
    else
      tracker
    end
  end

  defp new_track(object_id, object, context) do
    detected? = Observation.detected?(object)

    stale(
      %{
        object_id: object_id,
        camera_id: context.camera_id,
        label: object.label,
        bbox: object.bbox,
        score: object.score,
        best_score: object.score,
        source: if(plugin_tracked?(object, context), do: :plugin, else: :host),
        plugin_track_id: if(plugin_tracked?(object, context), do: object.track_id),
        epoch: context.epoch,
        started_at: context.observed_at,
        last_seen_at: context.observed_at,
        last_detected_at: if(detected?, do: context.observed_at),
        last_seen_ms: context.media_ms,
        last_detected_ms: if(detected?, do: context.media_ms),
        last_seen_host_ms: context.now_ms,
        stale_predicted: not detected?,
        # A track whose first observation is predicted has no anchor yet: the
        # first *detected* box is what the stillness rule measures against.
        anchor_bbox: if(detected?, do: object.bbox),
        anchor_ms: if(detected?, do: context.media_ms),
        recent_boxes: if(detected?, do: [object.bbox], else: []),
        stationary: false,
        stationary_since: nil,
        stationary_ms: 0
      },
      context
    )
  end

  defp update_track(tracked, object, context) do
    detected? = Observation.detected?(object)
    # Read before `last_detected_ms` moves below: stationary time accrues over
    # the gap between two *detections*, which is what this value is until then.
    previous_detected_ms = tracked.last_detected_ms

    %{
      tracked
      | label: object.label,
        bbox: object.bbox,
        score: object.score,
        best_score: max(tracked.best_score, object.score),
        last_seen_at: context.observed_at || tracked.last_seen_at,
        last_seen_ms: context.media_ms,
        last_seen_host_ms: context.now_ms,
        last_detected_at: if(detected?, do: context.observed_at, else: tracked.last_detected_at),
        last_detected_ms: if(detected?, do: context.media_ms, else: tracked.last_detected_ms)
    }
    |> stillness(object, detected?, previous_detected_ms, context)
    |> stale(context)
  end

  # -- stillness --------------------------------------------------------------

  # A predicted box is the plugin repeating itself, so it neither advances nor
  # resets stillness — see the moduledoc.
  defp stillness(tracked, _object, false, _previous_detected_ms, _context), do: tracked

  defp stillness(tracked, object, true, previous_detected_ms, context) do
    recent = Enum.take([object.bbox | tracked.recent_boxes], @recent_boxes)
    tracked = %{tracked | recent_boxes: recent}

    cond do
      is_nil(tracked.anchor_bbox) ->
        anchor(tracked, object.bbox, context)

      iou(tracked.anchor_bbox, median_box(recent)) >= @stationary_iou ->
        still(tracked, previous_detected_ms, context)

      true ->
        moved(tracked, object.bbox, context)
    end
  end

  # The anchor stays where it is for as long as the object does not move, so
  # the comparison spans the whole still stretch rather than one frame of it.
  defp still(%{stationary: true} = tracked, previous_detected_ms, context) do
    elapsed = max(context.media_ms - previous_detected_ms, 0)
    %{tracked | stationary_ms: tracked.stationary_ms + elapsed}
  end

  defp still(tracked, _previous_detected_ms, context) do
    if context.media_ms - tracked.anchor_ms >= context.stationary_after_ms do
      %{tracked | stationary: true, stationary_since: context.observed_at}
    else
      tracked
    end
  end

  defp moved(tracked, bbox, context) do
    %{anchor(tracked, bbox, context) | stationary: false, stationary_since: nil}
  end

  defp anchor(tracked, bbox, context),
    do: %{tracked | anchor_bbox: bbox, anchor_ms: context.media_ms}

  defp median_box(boxes), do: for(axis <- 0..3, do: median(Enum.map(boxes, &Enum.at(&1, axis))))

  defp median(values) do
    sorted = Enum.sort(values)
    mid = div(length(values), 2)

    if rem(length(values), 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end

  # -- expiry -----------------------------------------------------------------

  # A backwards pts jump inside an epoch makes the elapsed media time negative,
  # which is always `<= max_unseen_ms`, so it expires nothing — deliberate: the
  # whole scene must not die at once because a new ffmpeg run restarted the
  # timeline. The host clock is the backstop for the other direction, where the
  # elapsed media time never grows at all.
  defp expire(tracker, context) do
    {live, expired} = Enum.split_with(tracker.objects, fn {_id, o} -> live?(o, context) end)

    case expired do
      [] ->
        {tracker, []}

      _ ->
        dropped = MapSet.new(expired, fn {id, _object} -> id end)

        index =
          for {key, id} <- tracker.index,
              not MapSet.member?(dropped, id),
              into: %{},
              do: {key, id}

        {%{tracker | objects: Map.new(live), index: index},
         for({_id, object} <- expired, do: {:ended, to_track(object, :unseen)})}
    end
  end

  defp live?(object, context) do
    bound = unseen_bound(object, context)

    context.media_ms - object.last_seen_ms <= bound and
      context.now_ms - object.last_seen_host_ms <= @host_clock_factor * bound
  end

  # Both of `live?/2`'s conditions read this one value. Scale only the
  # media-time side and the backstop still caps a stationary track at
  # `@host_clock_factor * max_unseen_ms` of *host* time, which is the shorter
  # of the two on exactly the streams the grace has to survive — a stalled or
  # slow pts, where media time never reaches the extended bound at all.
  defp unseen_bound(%{stationary: true}, context),
    do: context.max_unseen_ms * @stationary_unseen_factor

  defp unseen_bound(_object, context), do: context.max_unseen_ms

  defp refresh_stale(tracker, context) do
    %{tracker | objects: Map.new(tracker.objects, fn {id, o} -> {id, stale(o, context)} end)}
  end

  defp stale(tracked, context) do
    %{tracked | stale_predicted: stale?(tracked, context)}
  end

  defp stale?(%{last_detected_ms: nil}, _context), do: true

  defp stale?(tracked, context),
    do: context.media_ms - tracked.last_detected_ms > context.max_unseen_ms

  # -- plugin identity map ----------------------------------------------------

  # Identity is scoped to `(plugin_instance, epoch, track_id)`. `plugin_instance`
  # separates concurrent plugins (camera id inline, group name for a group) and
  # `epoch` cuts identity at every ffmpeg respawn, so no track id crosses a
  # stream restart. It does *not* cover a plugin process restarting within an
  # epoch: the instance is static across respawns, so a restarted plugin that
  # reuses its old track ids resumes the ULIDs they were bound to.
  defp plugin_key(track_id, context),
    do: {context.plugin_instance, context.epoch, track_id}

  defp plugin_tracked?(object, %{tracking: true}), do: is_binary(object[:track_id])
  defp plugin_tracked?(_object, _context), do: false

  defp bind(tracker, key, object_id),
    do: %{tracker | index: Map.put(tracker.index, key, object_id)}

  defp forget_ended(tracker, key), do: %{tracker | ended: Map.delete(tracker.ended, key)}

  # Insertion-ordered by sequence so the set can be halved when it grows past
  # the cap — an epoch that runs for days must not accumulate ids forever.
  defp remember_ended(tracker, key) do
    ended = Map.put(tracker.ended, key, tracker.ended_seq)
    tracker = %{tracker | ended: ended, ended_seq: tracker.ended_seq + 1}

    if map_size(ended) > @max_ended_keys, do: halve_ended(tracker), else: tracker
  end

  defp halve_ended(tracker) do
    kept =
      tracker.ended
      |> Enum.sort_by(fn {_key, seq} -> -seq end)
      |> Enum.take(div(@max_ended_keys, 2))
      |> Map.new()

    %{tracker | ended: kept}
  end

  # -- summaries --------------------------------------------------------------

  defp to_track(tracked, end_reason \\ nil) do
    %Track{
      object_id: tracked.object_id,
      camera_id: tracked.camera_id,
      label: tracked.label,
      score: tracked.score,
      best_score: tracked.best_score,
      bbox: tracked.bbox,
      source: tracked.source,
      plugin_track_id: tracked.plugin_track_id,
      epoch: tracked.epoch,
      started_at: tracked.started_at,
      last_seen_at: tracked.last_seen_at,
      last_detected_at: tracked.last_detected_at,
      stale_predicted: tracked.stale_predicted,
      stationary: tracked.stationary,
      stationary_since: tracked.stationary_since,
      stationary_ms: tracked.stationary_ms,
      end_reason: end_reason
    }
  end
end
