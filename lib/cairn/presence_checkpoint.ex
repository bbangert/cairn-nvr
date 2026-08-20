defmodule Cairn.PresenceCheckpoint do
  @moduledoc """
  `Cairn.EventCheckpoint`'s shape for the presence lane: a public named ETS
  table holding each tier-1 camera's active event and the qualifying labels
  present at that moment, owned outside the pool so the row survives a
  `Cairn.PresenceRecorder` crash.

  A separate table rather than a second kind of row in `cairn_active_events`,
  and the separation is load-bearing: `Cairn.CameraTracker.restore_checkpointed/0`
  starts a `Cairn.CameraTracker` for every camera with a row in that table, so
  a presence event checkpointed there would grow tier-2 machinery on a tier-1
  camera at the next tracker-pool restart.

  Written and deleted by the recorder today; reading it back on restart lands
  with the recovery phase.
  """

  use GenServer

  @table :cairn_active_presence_events

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec put(String.t(), Cairn.Event.t(), [String.t()]) :: true
  def put(camera_id, %Cairn.Event{} = event, labels \\ []),
    do: :ets.insert(@table, {camera_id, event, labels})

  @spec delete(String.t()) :: true
  def delete(camera_id), do: :ets.delete(@table, camera_id)

  @doc """
  One camera's checkpoint, or `nil`.

  A read and not a take, `Cairn.EventCheckpoint.get/1`'s rule: the row stands
  for as long as the event is open, and whoever ends it deletes it.
  """
  @spec get(String.t()) :: {Cairn.Event.t(), [String.t()]} | nil
  def get(camera_id) do
    case :ets.lookup(@table, camera_id) do
      [{^camera_id, event, labels}] -> {event, labels}
      [] -> nil
    end
  end

  @spec all() :: [{String.t(), Cairn.Event.t(), [String.t()]}]
  def all, do: :ets.tab2list(@table)

  @doc "Empties the table in one operation."
  @spec clear() :: true
  def clear, do: :ets.delete_all_objects(@table)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])
    {:ok, %{}}
  end
end
