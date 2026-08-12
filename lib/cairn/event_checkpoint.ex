defmodule Cairn.EventCheckpoint do
  @moduledoc """
  Public named ETS table holding a snapshot of each camera's active event and
  the tracks live at that moment, owned by a process outside the trackers so
  the data survives a `Cairn.CameraTracker` crash. A replacement tracker
  restores its own camera's row from here (`get/1`) — re-attaching to a
  still-running extractor or dropping an orphaned entry, and ending every
  restored track (`:host_restart`), since the tracker element those tracks
  belonged to knows nothing of the replacement.

  The tracks are the snapshot the batch carried (`checkpoint_tracks/1` on the
  camera's tracker core), not something the writer derived: the tracking lives
  in the pipeline now, and this row is the only place it crosses into
  something that outlives one.
  """

  use GenServer

  @table :cairn_active_events

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec put(String.t(), Cairn.Event.t(), [Cairn.Track.t()]) :: true
  def put(camera_id, %Cairn.Event{} = event, tracks \\ []),
    do: :ets.insert(@table, {camera_id, event, tracks})

  @spec delete(String.t()) :: true
  def delete(camera_id), do: :ets.delete(@table, camera_id)

  @doc """
  One camera's checkpoint, or `nil`.

  A read and not a take: re-attaching to a live extractor leaves the row in
  place, because the event is still open and the *next* restore must find it.
  Whoever ends the event deletes it (`delete/1`).
  """
  @spec get(String.t()) :: {Cairn.Event.t(), [Cairn.Track.t()]} | nil
  def get(camera_id) do
    case :ets.lookup(@table, camera_id) do
      [{^camera_id, event, tracks}] -> {event, tracks}
      [] -> nil
    end
  end

  @spec all() :: [{String.t(), Cairn.Event.t(), [Cairn.Track.t()]}]
  def all, do: :ets.tab2list(@table)

  @doc """
  Empties the table in one operation.

  Deleting row by row off `all/0` is not atomic: anything inserting between
  the read and the deletes survives.
  """
  @spec clear() :: true
  def clear, do: :ets.delete_all_objects(@table)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])
    {:ok, %{}}
  end
end
