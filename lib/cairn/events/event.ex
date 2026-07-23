defmodule Cairn.Events.Event do
  @moduledoc """
  Event index row (SQLite). `labels` holds `%{"entries" => [...],
  "max_scores" => %{label => score}}` as written by the aggregator's
  runtime `Cairn.Event` at finalize time.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "events" do
    field :camera_id, :string
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :status, Ecto.Enum, values: [:active, :finalized, :partial], default: :active
    field :path, :string
    field :bytes, :integer
    field :labels, :map, default: %{}
    field :max_score, :float
    field :snapshot_path, :string

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @fields ~w(id camera_id started_at ended_at status path bytes labels max_score snapshot_path)a

  def changeset(event, attrs) do
    event
    |> cast(attrs, @fields)
    |> validate_required([:id, :camera_id, :started_at, :status])
    |> unique_constraint(:id, name: :events_pkey)
  end
end
