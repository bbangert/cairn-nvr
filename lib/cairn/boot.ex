defmodule Cairn.Boot do
  @moduledoc """
  One-shot boot task, run after the Repo (and migrations) are up:
  reconciles the event index with disk (Phase 5), then starts camera
  trees from the active config.
  """

  use Task, restart: :transient

  def start_link(opts) do
    Task.start_link(__MODULE__, :run, [opts])
  end

  @doc false
  def run(_opts) do
    reconcile()
    Cairn.CameraSupervisor.sync(Cairn.Config.Server.get())
  end

  # Phase 5 (task 5.4) replaces this with the disk-is-truth reconciliation.
  defp reconcile, do: :ok
end
