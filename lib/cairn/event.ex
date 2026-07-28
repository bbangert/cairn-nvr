defmodule Cairn.Event do
  @moduledoc """
  The event lifecycle contract (publisher-friendly).

  Broadcast on the internal PubSub topic `"events"` as
  `{:event_started | :event_updated | :event_ended, %Cairn.Event{}}` with a
  stable, JSON-serializable shape. The dashboard consumes it today;
  MQTT/webhook publishers can bolt on later without touching the
  aggregator. `Cairn.Track` publishes the object lifecycle on the same topic,
  and `Cairn.EventArtifact` the readiness of an event's clip and snapshot —
  `:event_ended` means the detection window closed, nothing more, so the
  media it names is not yet fetchable.

  `:event_ended` is **at-least-once**: an aggregator crash between the
  broadcast and the checkpoint delete replays it on restart (the replay may
  carry `status: :partial`). Consumers dedupe on `id`.

  `labels` is a time-indexed list of `%{t: seconds_since_start, label: l,
  score: s, object_id: id}` entries; `max_scores` maps label -> best score
  seen. `trigger` is the single highest-scoring detection of the event
  (`%{t, label, score, bbox, object_id}`) — the frame the snapshot is cut
  from, with the box drawn on it.

  `object_id` is a `Cairn.ULID` **string**, the identity of the track the
  detection belongs to (`%Cairn.Track{}.object_id`) — unique for the life of
  the installation, never reused across a stream epoch or a restart.
  """

  @derive Jason.Encoder
  @enforce_keys [:id, :camera_id, :started_at]
  defstruct [
    :id,
    :camera_id,
    :started_at,
    :ended_at,
    status: :active,
    labels: [],
    max_scores: %{},
    max_score: nil,
    trigger: nil,
    path: nil,
    snapshot_path: nil
  ]

  @type t :: %__MODULE__{}

  @topic "events"

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Cairn.PubSub, @topic)

  @spec broadcast(:event_started | :event_updated | :event_ended, t()) :: :ok
  def broadcast(kind, %__MODULE__{} = event) do
    Phoenix.PubSub.broadcast(Cairn.PubSub, @topic, {kind, event})
  end
end
