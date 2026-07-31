defmodule Cairn.Tracks.TrackEvent do
  @moduledoc """
  One discrete moment on a track's timeline (SQLite): it appeared, it settled,
  it started moving again.

  Frigate's shape — a handful of rows per track, not a dense path. `at` is the
  observation's own time, never the wall clock of the write, and the row dies
  with its track (`ON DELETE CASCADE`).

  Written only by `Cairn.Tracks.insert_batch/1` via `insert_all`, so there is
  no changeset, the same as `Cairn.Tracks.Track`.
  """

  use Ecto.Schema

  schema "track_events" do
    field :track_id, :string
    field :at, :utc_datetime_usec
    # Adding a kind means adding it here too, or the write raises on dump.
    field :kind, Ecto.Enum, values: [:appeared, :became_stationary, :started_moving]
    # `{:array, :any}` for the same reason as `Cairn.Tracks.Track`'s boxes: a
    # bbox is `[number()]` and `:float` will not dump an integer coordinate.
    field :bbox, {:array, :any}
  end

  @type t :: %__MODULE__{}
  @type kind :: :appeared | :became_stationary | :started_moving
end
