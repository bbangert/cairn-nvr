defmodule CairnWeb.Api.EventJSON do
  @moduledoc """
  Shapes events into the JSON contract exposed at `/api`.

  Two sources, one external shape:

    * `shape_row/1` — a persisted `Cairn.Events.Event` (the list/detail API).
    * `shape_live/1` — a runtime `Cairn.Event` broadcast on the `"events"`
      PubSub topic (the SSE feed).

  `shape_track/1` shapes the track lifecycle broadcast on the same topic, and
  `shape_artifact/2` the artifact-readiness kinds.

  On-disk paths (`path`, `snapshot_path`) are never emitted; media is reached
  only through the opaque, token-authed `clip_url` / `snapshot_url`.
  """

  alias Cairn.Events.Event

  @doc "Shapes a persisted event row for the read API."
  @spec shape_row(Event.t()) :: map()
  def shape_row(%Event{} = e) do
    %{
      id: e.id,
      camera_id: e.camera_id,
      started_at: e.started_at,
      ended_at: e.ended_at,
      status: e.status,
      bytes: e.bytes,
      max_score: e.max_score,
      labels: Map.get(e.labels || %{}, "max_scores", %{}),
      snapshot_url: media_url(e.snapshot_path, "/api/media/snapshots/#{e.id}"),
      clip_url: media_url(e.path, "/api/media/events/#{e.id}")
    }
  end

  @doc "Shapes a runtime `Cairn.Event` (SSE lifecycle frame)."
  @spec shape_live(Cairn.Event.t()) :: map()
  def shape_live(%Cairn.Event{} = e) do
    %{
      id: e.id,
      camera_id: e.camera_id,
      started_at: e.started_at,
      ended_at: e.ended_at,
      status: e.status,
      max_score: e.max_score,
      max_scores: e.max_scores,
      trigger: e.trigger,
      snapshot_url: media_url(e.snapshot_path, "/api/media/snapshots/#{e.id}"),
      clip_url: media_url(e.path, "/api/media/events/#{e.id}")
    }
  end

  @doc """
  Shapes a runtime `Cairn.Track` (SSE track lifecycle frame).

  Self-contained by design: a client that only ever sees `track_ended` still
  learns what the track was. `end_reason` is `null` while the track is live.
  """
  @spec shape_track(Cairn.Track.t()) :: map()
  def shape_track(%Cairn.Track{} = t) do
    %{
      object_id: t.object_id,
      camera_id: t.camera_id,
      label: t.label,
      score: t.score,
      best_score: t.best_score,
      bbox: t.bbox,
      source: t.source,
      plugin_track_id: t.plugin_track_id,
      started_at: t.started_at,
      last_seen_at: t.last_seen_at,
      last_detected_at: t.last_detected_at,
      stale_predicted: t.stale_predicted,
      stationary: t.stationary,
      stationary_since: t.stationary_since,
      stationary_ms: t.stationary_ms,
      end_reason: t.end_reason
    }
  end

  @doc """
  Shapes a `Cairn.PresenceEvent` broadcast (tier-1 presence transition).

  Self-contained like `shape_track/1`: a client that only sees the clearing
  still learns the zone, the label, the best score, and — via `first_seen_at`
  against `at` — the dwell. `state` spells the transition out so a client
  need not parse it back off the SSE event name.

  `zone` is on every presence frame, `null` for whole-frame presence on a
  camera with no zones (D-P4): one key set to parse, and the client's state
  key is `(camera_id, zone, label)`.
  """
  @spec shape_presence(Cairn.PresenceEvent.kind(), Cairn.PresenceEvent.t()) :: map()
  def shape_presence(kind, %Cairn.PresenceEvent{} = p) do
    %{
      camera_id: p.camera_id,
      zone: p.zone,
      label: p.label,
      state: presence_state(kind),
      score: p.score,
      first_seen_at: p.first_seen_at,
      at: p.at
    }
  end

  defp presence_state(:presence_started), do: "present"
  defp presence_state(:presence_cleared), do: "cleared"

  @doc """
  Shapes a `Cairn.EventArtifact` broadcast (clip/snapshot ready or failed).

  A `_ready` carries the URL the media is now fetchable at, a `_failed`
  carries that same key as `null` plus the `reason`. The broadcast's on-disk
  `path` is dropped — same rule as everywhere else in this module.
  """
  @spec shape_artifact(Cairn.EventArtifact.kind(), Cairn.EventArtifact.t()) :: map()
  def shape_artifact(:event_clip_ready, %Cairn.EventArtifact{} = a) do
    Map.put(base_artifact(a), :clip_url, "/api/media/events/#{a.event_id}")
  end

  def shape_artifact(:event_clip_failed, %Cairn.EventArtifact{} = a) do
    Map.put(base_artifact(a), :clip_url, nil)
  end

  def shape_artifact(:event_snapshot_ready, %Cairn.EventArtifact{} = a) do
    Map.put(base_artifact(a), :snapshot_url, "/api/media/snapshots/#{a.event_id}")
  end

  def shape_artifact(:event_snapshot_failed, %Cairn.EventArtifact{} = a) do
    Map.put(base_artifact(a), :snapshot_url, nil)
  end

  defp base_artifact(%Cairn.EventArtifact{} = a) do
    %{event_id: a.event_id, camera_id: a.camera_id, bytes: a.bytes, reason: a.reason}
  end

  # A URL only once a path has been recorded for it. That is not the same as
  # "the file is complete": `path` is written when recording *starts*, so an
  # `active` or `partial` row advertises a clip that may be truncated (see
  # ha-api.md). `snapshot_path` is written after the jpg exists.
  defp media_url(nil, _url), do: nil
  defp media_url(path, url) when is_binary(path), do: url
end
