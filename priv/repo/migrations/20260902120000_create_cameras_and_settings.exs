defmodule Cairn.Repo.Migrations.CreateCamerasAndSettings do
  use Ecto.Migration

  def change do
    create table(:cameras, primary_key: false) do
      # The slug, same `\A[a-z0-9][a-z0-9_-]*\z` id space the YAML parser
      # accepts — it names clip directories and history rows, so it is
      # never regenerated once assigned.
      add :id, :string, primary_key: true
      add :position, :integer, null: false
      add :enabled, :boolean, null: false, default: true

      # The YAML camera mapping minus `id`/`zones`, rendered back into the
      # `"cameras"` list in front of the unchanged `Cairn.Config.from_map/1`
      # — one validator, no changeset mirror.
      add :settings, :map, null: false

      # A JSON column, not a table: the editor writes one column and the
      # loader will render one key (`Cairn.Config.Camera` learns `zones` in
      # phase 2; `Cairn.Cameras.raw_maps/0` omits it until then).
      add :zones, {:array, :map}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cameras, [:position])

    # No FK from `events`/`tracks` to `cameras`: history outlives the row
    # until retention — deleting a camera keeps its clips.

    create table(:settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :map
    end

    # v1's only row is "yaml_import" — the import-once marker
    # `%{path, sha256, imported_at}`.
  end
end
