defmodule Cairn.LiveDetections do
  @moduledoc """
  What a camera's detector is seeing right now, for the live grid's overlay.

  One topic per camera, carrying `{:detections, camera_id, [detection]}`. Each
  message is one frame's COMPLETE list and REPLACES whatever the subscriber
  last drew, so an empty list is the positive statement that nothing is in
  view — no consumer needs a staleness timer to decide when a box has gone.

  `local_broadcast`, for `Cairn.CameraStatus`'s reason: the boxes are drawn
  over a video the browser is pulling from THIS node's WebRTC or MSE
  endpoint, so a subscriber on another node has no frame to put them on.

  The message names no lane. `Cairn.Pipeline.PresenceSink` is the only
  publisher today (tier 1); the tracked branch can publish the same shape
  without any consumer change.
  """

  alias Cairn.Observation

  @typedoc "Normalized `[x, y, w, h]`, each 0..1 — `Cairn.TrackPath`'s convention."
  @type detection :: %{label: String.t(), score: float(), bbox: [number()]}

  @spec topic(String.t()) :: String.t()
  def topic(camera_id), do: "camera:#{camera_id}:detections"

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(camera_id), do: Phoenix.PubSub.subscribe(Cairn.PubSub, topic(camera_id))

  @doc """
  Symmetry, and a way for a test to stop listening mid-case. Nothing in
  production calls it: a subscription is Registry-backed and dies with the
  subscribing process, which for the dashboard is the socket — there is no
  `terminate/2` to go looking for.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(camera_id), do: Phoenix.PubSub.unsubscribe(Cairn.PubSub, topic(camera_id))

  @spec broadcast(String.t(), [detection()]) :: :ok
  def broadcast(camera_id, detections) when is_list(detections) do
    Phoenix.PubSub.local_broadcast(
      Cairn.PubSub,
      topic(camera_id),
      {:detections, camera_id, detections}
    )
  end

  @doc """
  One frame's objects reduced to what an overlay can draw.

  Two filters, and only two. `observation_kind == "detected"`
  (`Cairn.Observation.detected?/1`) is the presence lane's evidence rule: a
  `"tracked"` object is a predictor's guess, and a live view claiming to show
  what the model sees must not draw one. A box needs four numbers to be
  positioned at all.

  Deliberately NOT filtered by the `min_score` floors or by `record:`. Those
  gate what presence *believes* and what earns a recording; the overlay
  answers a different question — what the model just reported — and an
  operator tuning a floor has to be able to see the detections it rejects.
  """
  @spec from_objects([map()]) :: [detection()]
  def from_objects(objects) when is_list(objects) do
    for %{bbox: [_, _, _, _] = bbox} = object <- objects,
        Observation.detected?(object),
        do: %{label: object.label, score: object.score, bbox: bbox}
  end
end
