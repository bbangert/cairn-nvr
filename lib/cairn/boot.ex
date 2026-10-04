defmodule Cairn.Boot do
  @moduledoc """
  One-shot boot task, run after the Repo (and migrations) are up:
  reconciles the event index with disk (Phase 5), then starts camera trees
  from the active config.
  """

  use Task, restart: :transient

  alias Cairn.Config.Server

  def start_link(opts) do
    Task.start_link(__MODULE__, :run, [opts])
  end

  @doc false
  def run(_opts) do
    config = Server.get()
    Cairn.Reconciler.run(config)
    Cairn.CameraSupervisor.sync(config)
  end
end
