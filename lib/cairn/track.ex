defmodule Cairn.Track do
  @moduledoc """
  One tracked object's public identity and lifecycle.

  Broadcast on the same `"events"` PubSub topic as `Cairn.Event` as
  `{:track_started | :track_updated | :track_ended, %Cairn.Track{}}`.
  `object_id` is a `Cairn.ULID` minted by `Cairn.Tracker` — the same string
  that appears in an event's `labels[].object_id` and `trigger.object_id`.

  A summary is **self-contained**: everything a consumer needs about the
  track is in the message, so a client that only ever sees the final
  `track_ended` still learns what the track was (ONVIF Analytics §A.10).

    * `source` — `:host` when Cairn's own IoU tracker owns the identity,
      `:plugin` when the plugin declared `object_tracking` and supplied
      `plugin_track_id`.
    * `score` is the latest observation's score, `best_score` the highest
      seen over the track's life.
    * `stale_predicted` — the track is alive but has not been *detected*
      recently (the plugin keeps predicting it). Never event evidence.
    * `stationary` — the object's box has held still for the camera's
      `stationary_after_ms` of media time; `stationary_since` is the
      observation time it flipped (`nil` while moving) and `stationary_ms`
      the total media time it has spent stationary over the track's whole
      life, which only ever grows — a track that moves and settles again
      carries the sum of both stretches.
    * `end_reason` is `nil` until the track ends: `:unseen` (expired),
      `:plugin_ended` (named in `ended_tracks`), `:stream_reset` (new stream
      epoch), `:evicted` (the camera hit its live-track cap and this was the
      least recently seen track), `:detection_disabled` (detection was turned
      off at runtime), `:host_restart` (restored from a checkpoint after a
      crash).

  ## How far the final-summary guarantee reaches

  A final is emitted for every lifecycle transition the aggregator observes:
  expiry, `ended_tracks`, an epoch boundary, an eviction, detection being
  disabled. It is **not** an unconditional guarantee across a crash, and what
  a crash costs is different for the two things a final feeds.

  `Cairn.EventCheckpoint` is behind both. It is an ETS table owned outside the
  aggregator, carrying a row per camera *only while that camera has an open
  event*, so it survives an aggregator crash but not the node — and even when
  it survives it knows nothing about a camera that had no event running.

    * **The `"events"` broadcast.** After an aggregator crash the tracks
      restored from a checkpoint are broadcast as `track_ended` with
      `:host_restart`. Tracks that were live on a camera with no open event
      are restored from nothing and get no `track_ended` at all, and a whole
      node restart loses the table, so nothing is restored and nothing gets a
      final. A consumer that materializes entities from `track_started` must
      therefore treat an aggregator restart, not only a `track_ended`, as the
      end of everything it holds.
    * **The track index** (`Cairn.Tracks`). `Cairn.TrackRecorder` buffers
      finished tracks and their moments in its own heap and writes them in
      batches, so a crash that takes *that* process or the node down loses
      whatever it had not flushed — deliberately, and on the same terms as an
      interrupted event written `:partial` (see that module's "Lossy by
      design"). Past that tail the checkpoint decides the same way:
      `Cairn.DetectionAggregator`'s restore writes a row for every
      checkpointed track, linked to the event it was live during, while a
      track that died on a camera with no open event gets no row either.

  Closing that second gap would be a change to what is checkpointed rather
  than to this contract: `Cairn.EventCheckpoint` already carries a track list,
  and only the "while an event is open" rule keeps a quiet camera's live
  tracks out of it.

  Times are the observation's own (`observed_at`), not the wall clock of
  the moment the message was built.
  """

  @derive Jason.Encoder
  @enforce_keys [:object_id, :camera_id]
  defstruct [
    :object_id,
    :camera_id,
    :label,
    :score,
    :best_score,
    :bbox,
    :source,
    :plugin_track_id,
    :epoch,
    :started_at,
    :last_seen_at,
    :last_detected_at,
    :end_reason,
    stale_predicted: false,
    stationary_since: nil,
    stationary: false,
    stationary_ms: 0
  ]

  @type t :: %__MODULE__{}
  @type kind :: :track_started | :track_updated | :track_ended
  @type end_reason ::
          :unseen
          | :plugin_ended
          | :stream_reset
          | :evicted
          | :detection_disabled
          | :host_restart

  # Cluster `broadcast`, like `Cairn.Event` and `Cairn.EventArtifact`: the
  # `"events"` topic is consumer-facing (SSE, dashboard) and a subscriber may
  # sit on any node, so one delivery mode has to cover the whole topic — a
  # remote consumer that saw `event_ended` but never the track or artifact
  # frames that follow it is stuck, not merely stale. Node-local, ETS-backed
  # internals (`Cairn.StreamEpochs`, `Cairn.CameraStatus`) stay on
  # `local_broadcast`: a remote subscriber could not read what they announce.
  @spec broadcast(kind(), t()) :: :ok
  def broadcast(kind, %__MODULE__{} = track)
      when kind in [:track_started, :track_updated, :track_ended] do
    Phoenix.PubSub.broadcast(Cairn.PubSub, Cairn.Event.topic(), {kind, track})
  end
end
