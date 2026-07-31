defmodule Cairn.Tracks.Track do
  @moduledoc """
  Track index row (SQLite) — one summary per tracked object, written once when
  the track ends.

  Not to be confused with `Cairn.Track`, the runtime broadcast struct: that one
  is the live lifecycle message, this one is the persisted summary derived from
  it — the same pairing as `Cairn.Event` (runtime) and `Cairn.Events.Event`
  (row).

  `event_id` is a plain string, not an association: events are pruned long
  before tracks are, so it dangles by design (see the migration). Nil means the
  track was never recorded, which is the audit question the table answers.

  Rows are written only by `Cairn.Tracks.insert_batch/1` via `insert_all`, so
  there is no changeset — the recorder's rows are machine-generated, the column
  types dump-check them, and `NOT NULL` covers what is required.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "tracks" do
    field :camera_id, :string
    field :event_id, :string
    field :label, :string
    field :best_score, :float
    field :source, Ecto.Enum, values: [:host, :plugin]
    field :plugin_track_id, :string
    field :epoch, :string
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    # Values mirror `Cairn.Track.end_reason/0` — adding one there means adding
    # it here, or the write raises on dump.
    field :end_reason, Ecto.Enum,
      values: [
        :unseen,
        :plugin_ended,
        :stream_reset,
        :evicted,
        :detection_disabled,
        :host_restart
      ]

    field :stationary_since, :utc_datetime_usec
    # `:integer` against a `:bigint` column, deliberately: Ecto has no wider
    # integer type, and this counter needs the width — a year parked is ~3.2e10
    # ms, well past int32.
    field :stationary_ms, :integer, default: 0
    # `{:array, :any}`, not `{:array, :float}`: a bbox is `[number()]` and Ecto
    # refuses to dump an integer coordinate through a `:float` type.
    field :entry_bbox, {:array, :any}
    field :exit_bbox, {:array, :any}
    field :best_bbox, {:array, :any}
    field :zones, {:array, :string}, default: []

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
