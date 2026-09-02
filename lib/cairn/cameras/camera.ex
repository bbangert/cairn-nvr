defmodule Cairn.Cameras.Camera do
  @moduledoc """
  A camera row. `settings` is the YAML camera mapping minus `id`/`zones`
  (rendered back through `Cairn.Cameras.raw_maps/0` in front of
  `Cairn.Config.from_map/1`); `zones` is its own column because the editor
  writes one column and the loader will render one key — `Config.Camera`
  learns `zones` in phase 2, and `raw_maps/0` omits it until then.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Cairn.Config

  @primary_key {:id, :string, autogenerate: false}
  schema "cameras" do
    field :position, :integer
    field :enabled, :boolean, default: true
    field :settings, :map, default: %{}
    field :zones, {:array, :map}, default: []

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  # Anchored to agree with the YAML parser's id space (`Cairn.Config.Camera`)
  # so a row and a file camera accept exactly the same slugs.
  @id_regex Regex.compile!("\\A#{Config.Camera.id_class()}\\z")

  @fields ~w(id position enabled settings zones)a
  @update_fields ~w(position enabled settings zones)a

  @doc "Create changeset — `:id` is set once here and never after."
  def changeset(camera, attrs) do
    camera
    |> cast(attrs, @fields)
    |> validate_required([:id, :position])
    |> validate_format(:id, @id_regex,
      message: "must be lowercase [a-z0-9_-] starting with a letter or digit"
    )
    |> validate_number(:position, greater_than_or_equal_to: 0)
    # `zones` is only checked here to be a list of maps (what the `{:array,
    # :map}` cast already enforces) — `Cairn.Zones` validates shape in
    # phase 2.
    # `ecto_sqlite3` reports a string primary key's index as
    # `cameras_id_index`, not a Postgres-style `_pkey` name.
    |> unique_constraint(:id, name: :cameras_id_index)
  end

  @doc "Update changeset — omits `:id`: the slug is immutable, see moduledoc."
  def update_changeset(camera, attrs) do
    camera
    |> cast(attrs, @update_fields)
    |> validate_required([:position])
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end
end
