defmodule Cairn.PresenceSupervisor do
  @moduledoc """
  The presence lane's two node-level tables: `Cairn.PresenceCheckpoint` and
  `Cairn.PresenceLedger`.

  The workers that read them are not here — a tier-1 camera's
  `Cairn.PresenceAggregator` and `Cairn.PresenceRecorder` are children of that
  camera's own `Cairn.Camera.Lane`, so they start and stop with the camera. The
  tables are per-node and outlive any one of them, which is the whole point:
  what a restarted aggregator owes the world is not its state but the
  `presence_cleared` events its predecessor's announcements are still waiting
  on.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # `:rest_for_one`, checkpoint before ledger: a checkpoint crash empties the
  # ledger too, so a recorder restarting afterwards cannot restore an event
  # from a row whose announced keys it has no way to check. The reverse is
  # harmless and stays harmless — a ledger crash leaves the checkpoint alone.
  #
  # The extractors live under `Cairn.EventSupervisor` and go on writing their
  # clips through a crash here, so a `Cairn.PresenceCheckpoint` crash destroys
  # the only record of them. What covers that is the sweep in
  # `Cairn.PresenceRecorder`'s restore: a recorder that finds no checkpoint row
  # asks the event index and the registry whether an extractor of its camera is
  # still writing, and ends what it finds.
  @impl true
  def init(_opts) do
    Supervisor.init([Cairn.PresenceCheckpoint, Cairn.PresenceLedger], strategy: :rest_for_one)
  end
end
