defmodule Cairn.Event do
  @moduledoc """
  The event lifecycle contract (publisher-friendly).

  Broadcast on the internal PubSub topic `"events"` as
  `{:event_started | :event_updated | :event_ended, %Cairn.Event{}}` with a
  stable, JSON-serializable shape. The dashboard consumes it today;
  MQTT/webhook publishers can bolt on later without touching the
  aggregator.

  `labels` is a time-indexed list of `%{t: seconds_since_start, label: l,
  score: s, object_id: id}` entries; `max_scores` maps label -> best score
  seen.
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
