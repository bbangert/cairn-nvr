defmodule Cairn.DetectionAggregator do
  @moduledoc """
  Owns event lifecycle per camera: receives decoded detections from plugin
  ports, filters by per-label `min_score`, tracks objects, and starts /
  finalizes `Cairn.EventExtractor`s.

  Phase 1: stub that accepts and drops detections (real logic in Phase 4).
  """

  use GenServer

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Called by `Cairn.PluginPort` with a decoded detection batch."
  @spec detections(GenServer.server(), map()) :: :ok
  def detections(server \\ __MODULE__, batch) do
    GenServer.cast(server, {:detections, batch})
  end

  @impl true
  def init(opts) do
    {:ok, %{opts: opts}}
  end

  @impl true
  def handle_cast({:detections, _batch}, state) do
    {:noreply, state}
  end
end
