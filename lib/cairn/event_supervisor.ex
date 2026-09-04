defmodule Cairn.EventSupervisor do
  @moduledoc """
  DynamicSupervisor over `Cairn.EventExtractor` processes — one `:temporary`
  child per active event.

  Its `Cairn.CameraReaper` (`Cairn.EventSupervisor.Reaper`) is a sibling under
  the application supervisor rather than a child, since this is a
  DynamicSupervisor: it ends the extractors of a camera the config no longer
  names, which no lane owner is left to finalize.
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
