defmodule Cairn.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add :id, :string, primary_key: true
      add :camera_id, :string, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :status, :string, null: false, default: "active"
      add :path, :string
      add :bytes, :integer
      add :labels, :map, null: false, default: %{}
      add :max_score, :float
      add :snapshot_path, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:events, [:camera_id, :started_at])
    create index(:events, [:status])
  end
end
