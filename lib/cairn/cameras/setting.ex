defmodule Cairn.Cameras.Setting do
  @moduledoc """
  A KV row. v1's only key is `"yaml_import"`, the import-once marker
  `%{path, sha256, imported_at}`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  schema "settings" do
    field :value, :map
  end

  @type t :: %__MODULE__{}

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key])
  end
end
