defmodule Cairn.EventCheckpoint do
  @moduledoc """
  Public named ETS table holding a snapshot of each camera's active event,
  owned by a process outside the aggregator so the data survives an
  aggregator crash. On restart the aggregator restores from here —
  re-attaching to still-running extractors or dropping orphaned entries.
  """

  use GenServer

  @table :cairn_active_events

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec put(String.t(), Cairn.Event.t()) :: true
  def put(camera_id, %Cairn.Event{} = event), do: :ets.insert(@table, {camera_id, event})

  @spec delete(String.t()) :: true
  def delete(camera_id), do: :ets.delete(@table, camera_id)

  @spec all() :: [{String.t(), Cairn.Event.t()}]
  def all, do: :ets.tab2list(@table)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])
    {:ok, %{}}
  end
end
