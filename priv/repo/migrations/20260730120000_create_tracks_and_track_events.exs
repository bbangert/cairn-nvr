defmodule Cairn.Repo.Migrations.CreateTracksAndTrackEvents do
  use Ecto.Migration

  def change do
    create table(:tracks, primary_key: false) do
      # The tracker's ULID `object_id` — the same string a detection carries in
      # an event's `labels[].object_id` — so a track row is joinable to event
      # evidence by value. String PK mirrors `events`.
      add :id, :string, primary_key: true
      add :camera_id, :string, null: false

      # Deliberately a plain string column with NO foreign key to `events`.
      # Events are pruned at ~14 days and tracks at 365, so the referenced row
      # is *expected* to vanish while the track lives on. Both FK behaviours are
      # wrong here: restrict blocks the event retention sweep, and nilify erases
      # "this track was recorded" — the audit fact this table exists to hold. A
      # dangling id is the correct end state: a clip existed and has aged out.
      add :event_id, :string

      add :label, :string
      add :best_score, :float
      add :source, :string
      add :plugin_track_id, :string
      add :epoch, :string
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :end_reason, :string
      add :stationary_since, :utc_datetime_usec
      add :stationary_ms, :bigint, null: false, default: 0

      # Boxes are `Cairn.Tracker.bbox()` — a JSON array of four numbers, as the
      # plugin sent them, ints or floats. Hence `:any` and not `:float`: Ecto
      # refuses to dump an integer through a `:float` type. SQLite stores the
      # column as TEXT either way.
      add :entry_bbox, {:array, :any}
      add :exit_bbox, {:array, :any}
      add :best_bbox, {:array, :any}

      # Schema-reserved for zone occupancy; nothing writes it yet.
      add :zones, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tracks, [:camera_id, :started_at])
    create index(:tracks, [:label])
    create index(:tracks, [:event_id])
    # The retention sweep's cutoff column.
    create index(:tracks, [:ended_at])

    create table(:track_events) do
      # ON DELETE CASCADE, deliberately asymmetric with `tracks.event_id` above:
      # a moment is meaningless without the track it describes, so it dies with
      # it; a track is still meaningful once its clip is gone, so it holds no FK
      # in the other direction.
      add :track_id, references(:tracks, type: :string, on_delete: :delete_all), null: false
      add :at, :utc_datetime_usec, null: false
      add :kind, :string, null: false
      add :bbox, {:array, :any}

      # No timestamps: `at` is the moment's own observation time, and a row
      # inserted at flush time would only record the recorder's buffering lag.
    end

    create index(:track_events, [:track_id])
  end
end
