defmodule Cairn.Boot do
  @moduledoc """
  One-shot boot task, run after the Repo (and migrations) are up:
  reconciles the event index with disk (Phase 5), then starts plugin groups
  and camera trees from the active config.
  """

  use Task, restart: :transient

  def start_link(opts) do
    Task.start_link(__MODULE__, :run, [opts])
  end

  @doc false
  def run(_opts) do
    config = Cairn.Config.Server.get()
    Cairn.Reconciler.run(config)
    Cairn.PluginGroupSupervisor.sync(config)
    Cairn.CameraSupervisor.sync(config)
  end
end
