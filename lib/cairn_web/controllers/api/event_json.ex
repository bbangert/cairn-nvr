defmodule CairnWeb.Api.EventJSON do
  @moduledoc """
  Shapes events into the JSON contract exposed at `/api`.

  Two sources, one external shape:

    * `shape_row/1` — a persisted `Cairn.Events.Event` (the list/detail API).
    * `shape_live/1` — a runtime `Cairn.Event` broadcast on the `"events"`
      PubSub topic (the SSE feed).

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

  # Only advertise a URL once the underlying file exists on disk.
  defp media_url(nil, _url), do: nil
  defp media_url(path, url) when is_binary(path), do: url
end
