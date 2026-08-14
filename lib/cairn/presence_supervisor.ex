defmodule Cairn.PresenceSupervisor do
  @moduledoc """
  The presence subtree: one `Cairn.PresenceAggregator` per tier-1 camera,
  started on demand and restarted after a crash.

  Not a child of `Cairn.TrackerSupervisor` — that tree is tracking's, with a
  checkpoint-restore sweep presence has no use for (nothing here is
  persisted, so a restarted aggregator correctly starts knowing nothing and
  re-confirms from the next batches).

  The default restart intensity is kept deliberately: one aggregator
  crash-looping past it takes this pool down and every camera's presence
  state with it — the same cascade bargain `Cairn.TrackerSupervisor.Pool`
  makes — and the application root restarts the pool empty, which for
  state this ephemeral is a correct recovery, not a loss.
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
