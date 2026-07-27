defmodule CairnWeb.Api.EventJSON do
  @moduledoc """
  Shapes events into the JSON contract exposed at `/api`.

  Two sources, one external shape:

    * `shape_row/1` — a persisted `Cairn.Events.Event` (the list/detail API).
    * `shape_live/1` — a runtime `Cairn.Event` broadcast on the `"events"`
      PubSub topic (the SSE feed).

  `shape_track/1` shapes the track lifecycle broadcast on the same topic.

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
      end_reason: t.end_reason
    }
  end

  # Only advertise a URL once the underlying file exists on disk.
  defp media_url(nil, _url), do: nil
  defp media_url(path, url) when is_binary(path), do: url
end
