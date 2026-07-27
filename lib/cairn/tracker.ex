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

  Media time may jump backwards (a new ffmpeg run restarts the RTP timeline).
  Within an epoch that only makes the elapsed time negative, which never
  expires anything; across epochs the aggregator ends every track and starts
  a fresh tracker.

  Bboxes are `[x, y, w, h]` in any consistent unit (normalized or pixels).
  """

  require Logger

  alias Cairn.Observation
  alias Cairn.Track
  alias Cairn.ULID

  @iou_threshold 0.1
  # Plugin track ids that have been ended, kept so their reuse can be caught.
  # Only live tracks bound the rest of the state; this set is bounded here.
  @max_ended_keys 4_096

  defstruct objects: %{}, index: %{}, ended: %{}, ended_seq: 0

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
          max_unseen_ms: number()
        }

  @type event :: {:started | :updated | :ended, Track.t()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Builds the tracking context for one observation.

  `camera_id` is the caller's — the aggregator keys its state by the
  *configured* camera, and that is what a track summary must name, whatever
  the plugin put on the wire.
  """
  @spec context(Observation.t(), String.t(), number()) :: context()
  def context(%Observation{} = observation, camera_id, max_unseen_ms) do
    %{
      camera_id: camera_id,
      epoch: observation.epoch,
      plugin_instance: observation.plugin_instance,
      media_ms: observation.media_ms,
      observed_at: observation.observed_at,
      tracking: observation.tracking,
      ended_tracks: observation.ended_tracks,
      max_unseen_ms: max_unseen_ms
    }
  end

  @doc """
  Folds one observation's objects into the tracker.

  Returns `{tracker, tagged_objects, events}`: every object tagged with its
  `object_id` (ULID) and `stale_predicted` flag, in the order given, and the
  lifecycle events this observation caused.
  """
  @spec track(t(), [map()], context()) :: {t(), [map()], [event()]}
  def track(%__MODULE__{} = tracker, objects, context) do
    {tracker, ended} = end_plugin_tracks(tracker, context)
    {tracker, assignments} = assign(tracker, objects, context)
    {tracker, tagged, lifecycle} = apply_assignments(tracker, objects, assignments, context)
    {tracker, expired} = expire(tracker, context)

    {refresh_stale(tracker, context), tagged, ended ++ lifecycle ++ expired}
  end

  @doc """
  Ends every live track with `reason` and returns a fresh tracker.

  Used at a stream-epoch boundary: no track may span the cut, and every track
  owes its consumers a final summary.
  """
  @spec end_all(t(), Track.end_reason()) :: {t(), [event()]}
  def end_all(%__MODULE__{} = tracker, reason) do
    {new(), for({_id, object} <- tracker.objects, do: {:ended, to_track(object, reason)})}
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

  # `%{object index => object_id}`; an index with no entry is a new track.
  defp assign(tracker, objects, context) do
    {plugin, host} =
      objects
      |> Enum.with_index()
      |> Enum.split_with(fn {object, _index} -> plugin_tracked?(object, context) end)

    {tracker, plugin_assignments} = assign_plugin(tracker, plugin, context)
    {tracker, Map.merge(plugin_assignments, assign_host(tracker, host))}
  end

  defp assign_plugin(tracker, indexed, context) do
    Enum.reduce(indexed, {tracker, %{}}, fn {object, index}, {tracker, assignments} ->
      key = plugin_key(object.track_id, context)
      {tracker, object_id} = plugin_identity(tracker, key, object, context)
      {tracker, Map.put(assignments, index, object_id)}
    end)
  end

  defp plugin_identity(tracker, key, object, context) do
    if Map.has_key?(tracker.ended, key) do
      Logger.warning(
        "camera #{context.camera_id}: plugin #{inspect(context.plugin_instance)} reused " <>
          "track id #{inspect(object.track_id)} after ending it — tracking it as a new object"
      )

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
  # host-owned tracks are candidates: a plugin's identities are its own.
  defp assign_host(tracker, indexed) do
    candidates = for {id, object} <- tracker.objects, object.source == :host, do: {id, object}

    pairs =
      for {object, index} <- indexed,
          {id, tracked} <- candidates,
          tracked.label == object.label,
          overlap = iou(tracked.bbox, object.bbox),
          overlap >= @iou_threshold do
        {overlap, index, id}
      end

    {assignments, _used_objects, _used_tracks} =
      pairs
      |> Enum.sort_by(fn {overlap, _index, _id} -> -overlap end)
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

  defp apply_assignments(tracker, objects, assignments, context) do
    {tracker, tagged, events} =
      objects
      |> Enum.with_index()
      |> Enum.reduce({tracker, [], []}, fn {object, index}, {tracker, tagged, events} ->
        object_id = Map.get(assignments, index) || ULID.generate()

        {tracked, kind} =
          case Map.fetch(tracker.objects, object_id) do
            {:ok, existing} -> {update_track(existing, object, context), :updated}
            :error -> {new_track(object_id, object, context), :started}
          end

        tracker = %{tracker | objects: Map.put(tracker.objects, object_id, tracked)}
        tag = Map.merge(object, %{object_id: object_id, stale_predicted: tracked.stale_predicted})

        {tracker, [tag | tagged], [{kind, to_track(tracked)} | events]}
      end)

    {tracker, Enum.reverse(tagged), Enum.reverse(events)}
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
        stale_predicted: not detected?
      },
      context
    )
  end

  defp update_track(tracked, object, context) do
    detected? = Observation.detected?(object)

    stale(
      %{
        tracked
        | label: object.label,
          bbox: object.bbox,
          score: object.score,
          best_score: max(tracked.best_score, object.score),
          last_seen_at: context.observed_at || tracked.last_seen_at,
          last_seen_ms: context.media_ms,
          last_detected_at:
            if(detected?, do: context.observed_at, else: tracked.last_detected_at),
          last_detected_ms: if(detected?, do: context.media_ms, else: tracked.last_detected_ms)
      },
      context
    )
  end

  # -- expiry -----------------------------------------------------------------

  # Elapsed media time, never negative: a backwards pts jump inside an epoch
  # must not expire the whole scene at once.
  defp expire(tracker, context) do
    {live, expired} =
      Enum.split_with(tracker.objects, fn {_id, object} ->
        context.media_ms - object.last_seen_ms <= context.max_unseen_ms
      end)

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
      end_reason: end_reason
    }
  end
end
