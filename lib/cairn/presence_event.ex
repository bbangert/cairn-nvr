defmodule Cairn.PresenceEvent do
  @moduledoc """
  A tier-1 camera's per-class presence transition: `label` became present in
  `zone`, or cleared after being present there. `zone` is a zone id, or
  `nil` for whole-frame presence on a camera with no zones — every consumer
  that keeps state keys it by `{camera_id, zone, label}`, and the SSE frame
  always carries the field (D-P4), so a client has one key set to parse.

  Its own leg of the event surface, not an extension of `Cairn.Track` (D-S3):
  presence carries no identity — no object id, no bbox trail, nothing to
  persist — so a track-shaped spelling would promise fields tier 1 cannot
  honestly fill. `Cairn.TrackRecorder` does not persist these; a presence
  history store is future work.

  The transition kind rides the broadcast tuple, `Cairn.Track.broadcast/2`'s
  shape, so the struct holds only what both kinds share. `first_seen_at`
  survives into `:presence_cleared`, making dwell (`at - first_seen_at`)
  readable off the clearing event alone.
  """

  @enforce_keys [:camera_id, :label, :first_seen_at, :at]
  defstruct [:camera_id, :zone, :label, :score, :first_seen_at, :at]

  @type t :: %__MODULE__{
          camera_id: String.t(),
          zone: String.t() | nil,
          label: String.t(),
          # The best score seen so far while present — at confirm time for
          # `:presence_started`, over the whole stay for `:presence_cleared`.
          score: float() | nil,
          first_seen_at: DateTime.t(),
          at: DateTime.t()
        }

  @type kind :: :presence_started | :presence_cleared

  @doc "Publishes on the events topic — cluster-wide, like `Cairn.Track`."
  @spec broadcast(kind(), t()) :: :ok
  def broadcast(kind, %__MODULE__{} = event)
      when kind in [:presence_started, :presence_cleared] do
    Phoenix.PubSub.broadcast(Cairn.PubSub, Cairn.Event.topic(), {kind, event})
  end
end
