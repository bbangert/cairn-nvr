defmodule Cairn.PresenceSupervisor do
  @moduledoc """
  The presence subtree: one `Cairn.PresenceAggregator` and one
  `Cairn.PresenceRecorder` per tier-1 camera, started on demand and restarted
  after a crash.

  Not a child of `Cairn.TrackerSupervisor` — that tree is tracking's, and its
  checkpoint-restore sweep is the one presence must never be swept by
  (`Cairn.PresenceCheckpoint`'s keyspace argument). What a restarted
  aggregator owes the world is not its state but the `presence_cleared`
  events its predecessor's announcements are still waiting on, which is the
  `Cairn.PresenceLedger`'s job to make possible.

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

  # `:rest_for_one`, tables before the pool: aggregators and recorders die
  # without taking the announced set or the active-event rows with them, while
  # a table's own crash restarts the pool into the empty world the fresh table
  # reflects. What each survival buys differs today — an aggregator's restart
  # reads the ledger and clears what its predecessor promised, while a
  # recorder's checkpoint is only written and deleted, for the recovery phase
  # to read back.
  @impl true
  def init(_opts) do
    children = [
      Cairn.PresenceCheckpoint,
      Cairn.PresenceLedger,
      {DynamicSupervisor, name: Cairn.PresenceSupervisor.Pool, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
