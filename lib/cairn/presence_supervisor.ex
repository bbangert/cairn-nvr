defmodule Cairn.PresenceSupervisor do
  @moduledoc """
  The presence subtree: one `Cairn.PresenceAggregator` and one
  `Cairn.PresenceRecorder` per tier-1 camera, started on demand and restarted
  after a crash, plus the `Cairn.CameraReaper` that stops a recorder whose
  camera the config no longer names — the one stop the recorder's retire latch
  must not outlive.

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
  # reflects. Both survivals are read on restart — an aggregator clears what
  # its predecessor announced, and a recorder re-attaches to the extractor its
  # predecessor's checkpoint names, adopting from the ledger the labels that
  # checkpoint could not have known about.
  #
  # That empty world is not quite empty, and one thing outside this tree is why:
  # the extractors live under `Cairn.EventSupervisor` and go on writing their
  # clips through a crash here. A `Cairn.PresenceCheckpoint` crash therefore
  # destroys the only record of them at the same moment it kills everyone who
  # could finalize them. What makes the sentence above safe is the sweep in
  # `Cairn.PresenceRecorder`'s restore: a recorder that finds no checkpoint row
  # asks the event index and the registry whether an extractor of its camera is
  # still writing, and ends what it finds.
  @impl true
  def init(_opts) do
    children = [
      Cairn.PresenceCheckpoint,
      Cairn.PresenceLedger,
      {DynamicSupervisor, name: Cairn.PresenceSupervisor.Pool, strategy: :one_for_one},
      # Last, so its own crash restarts nothing: it holds no state but a
      # subscription, and the pool restarting above it takes it with them.
      {Cairn.CameraReaper, role: :presence_recorder, name: Cairn.PresenceSupervisor.Reaper}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
