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

    * `source` — always `:host`: Cairn's own IoU tracker owns every identity
      it mints. Plugin-owned tracking was removed, so `:plugin` appears only
      on historical rows in the track index, and `plugin_track_id` is reserved
      and unused (nothing sets it for a new track).
    * `score` is the latest observation's score, `best_score` the highest
      seen over the track's life.
    * `stale_predicted` — the track is alive but has not been *detected*
      recently (the plugin keeps predicting it). Never event evidence.
    * `stationary` — the object's box has held still for the camera's
      `stationary_after_ms` of the tracking clock (`Cairn.ObservationClock`);
      `stationary_since` is the
      observation time it flipped (`nil` while moving) and `stationary_ms`
      the total time on that clock it has spent stationary over the track's whole
      life, which only ever grows — a track that moves and settles again
      carries the sum of both stretches. The flag is hysteretic in both
      directions: it clears only after the box has *kept* failing the
      stillness test for `Cairn.Tracker`'s exit window, so a stationary track
      whose detector jitters stays flagged and a real departure is reported a
      couple of seconds after it starts. Nothing intermediate is published —
      a track waiting out that window is `stationary: true` like any other.
    * `epoch` is the stream the track was last observed under, not the one it
      was minted in: a host track can survive a stream reset by being adopted
      on the far side of it (`Cairn.Tracker`), keeping its `object_id` and its
      `started_at` while its `epoch` moves on.
    * `end_reason` is `nil` until the track ends: `:unseen` (expired),
      `:stream_reset` (a new stream epoch severed it and nothing adopted it),
      `:evicted` (the camera hit its live-track cap and this was the least
      recently seen track), `:detection_disabled` (detection was turned off at
      runtime), `:host_restart` (restored from a checkpoint after a crash).
      `:plugin_ended` is retained in the type but no longer emitted — like
      `:plugin` above, it appears only on historical rows.

  A `:stream_reset` final can arrive long after the times it carries. A host
  track cut by a stream reset is suspended rather than ended, and only when its
  adoption window runs out with nothing having adopted it is the final emitted
  — timestamped at the last observation before the cut, because that is when
  the object was last actually seen. The window is a minute from the *cut*, and
  the cut can itself be well after that last observation: a stream that goes
  quiet is not cut until ffmpeg gives up on it. Nothing is broadcast in
  between: a consumer either sees the track resume (as `track_updated`, on the
  new epoch) or sees it end once, and never sees it end twice.

  ## How far the final-summary guarantee reaches

  A final is emitted for every lifecycle transition the camera's
  `Cairn.CameraTracker` observes: expiry, an epoch boundary, an eviction,
  detection being disabled. It is **not** an unconditional guarantee across a
  crash, and what a crash costs is different for the two things a final feeds.

  `Cairn.EventCheckpoint` is behind both. It is an ETS table owned outside the
  trackers, carrying a row per camera *only while that camera has an open
  event*, so it survives a tracker crash but not the node — and even when
  it survives it knows nothing about a camera that had no event running.

    * **The `"events"` broadcast.** After a tracker crash the tracks its
      replacement restores from the checkpoint are broadcast as `track_ended`
      with `:host_restart`. Tracks that were live on a camera with no open
      event are restored from nothing and get no `track_ended` at all, and a
      whole node restart loses the table, so nothing is restored and nothing
      gets a final. A consumer that materializes entities from `track_started`
      must therefore treat a tracker restart, not only a `track_ended`, as the
      end of everything it holds for that camera. It does not have to wait long
      for the finals it does get: the tracker is `:transient`, so its
      supervisor restarts it and the replacement restores in `init/1` rather
      than on that camera's next observation. What arrives then is still only
      what the checkpoint held.
    * **The track index** (`Cairn.Tracks`). Here a crash costs much less,
      because the row does not wait for the final: `Cairn.TrackRecorder` opens
      it as soon as the track passes the camera's `track:` tier and refreshes
      it as the track runs. A crash that takes that process or the node down
      loses only what it had not flushed — at most a batch, deliberately, and
      on the same terms as an interrupted event written `:partial` (see that
      module's "Lossy by design"). What is lost is the *tail* of a row that
      exists, or the whole of one for a track that qualified within the last
      flush interval.

      The row is left open by such a crash, since the close is what went
      missing. Two things close it afterwards, neither needing a broadcast:
      `Cairn.CameraTracker`'s restore finalizes every checkpointed track
      against the event it was live during, and `Cairn.Tracks.close_live/0`
      closes everything still open at the next boot — including the tracks of
      quiet cameras, which no checkpoint ever held.

  So the second gap above is a gap in the *broadcast* contract only. A
  consumer that needs the tracks of a camera with no open event to survive a
  crash reads them out of the index, where they are.

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
