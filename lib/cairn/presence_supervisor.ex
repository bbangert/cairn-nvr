defmodule Cairn.PresenceSupervisor do
  @moduledoc """
  The presence subtree: one `Cairn.PresenceAggregator` per tier-1 camera,
  started on demand and restarted after a crash.

  Not a child of `Cairn.TrackerSupervisor` — that tree is tracking's, with a
  checkpoint-restore sweep presence has no use for (nothing here is
  persisted; what a restarted aggregator owes the world is not its state
  but the `presence_cleared` events its predecessor's announcements are
  still waiting on, which is the `Cairn.PresenceLedger`'s job to make
  possible).

  The pool keeps the default restart intensity deliberately: one
  aggregator crash-looping past it takes the pool down and every camera's
  presence state with it — the same cascade bargain
  `Cairn.TrackerSupervisor.Pool` makes — and the restarted, on-demand
  aggregators clear whatever the ledger says the dead ones had announced.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # `:rest_for_one`, ledger first: aggregators die without taking the
  # announced set with them (that set is what makes their crash recovery
  # able to clear what the dead process promised), while a ledger crash
  # restarts the pool into the empty world the fresh table reflects.
  @impl true
  def init(_opts) do
    children = [
      Cairn.PresenceLedger,
      {DynamicSupervisor, name: Cairn.PresenceSupervisor.Pool, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
