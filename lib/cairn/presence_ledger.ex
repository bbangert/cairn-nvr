defmodule Cairn.PresenceLedger do
  @moduledoc """
  The announced set: every `{camera, label}` a `presence_started` went out
  for and no `presence_cleared` has yet answered.

  Exists for one reason — the every-started-gets-a-cleared invariant must
  survive an aggregator crash. Presence is edge-only and unpersisted, so a
  restarted aggregator that starts blank leaves every client that tracked
  the edges stuck at "present" forever; instead its `init` reads this table
  and clears what the dead process had announced. The table therefore lives
  beside the pool, not in it: `Cairn.PresenceSupervisor` starts this
  process first and the pool `:rest_for_one` after it, so a crashing
  aggregator — or the whole pool — never takes the ledger down, while a
  ledger crash restarts the pool into the empty world it now reflects. A
  collapse of the entire supervisor loses the set; so does the VM — that is
  the depth of guarantee an in-memory ledger buys, and the moduledoc of
  `Cairn.PresenceAggregator` states the recovery bargain it serves.

  Writes come only from aggregators, on the same process that broadcasts,
  ordered for at-least-once recovery: the row is inserted BEFORE the
  started may go out and deleted only AFTER the cleared has — a crash
  between either pair costs a duplicate cleared, never a missing one.
  """

  use GenServer

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Record an announced `{camera, label}` — called before the started broadcast."
  @spec announced(String.t(), String.t(), DateTime.t(), float() | nil) :: true
  def announced(camera_id, label, first_seen_at, score) do
    :ets.insert(@table, {{camera_id, label}, first_seen_at, score})
  end

  @doc "The matching cleared went out."
  @spec cleared(String.t(), String.t()) :: true
  def cleared(camera_id, label), do: :ets.delete(@table, {camera_id, label})

  @doc "Rows a dead aggregator left for `camera_id` — its restart clears them."
  @spec leftovers(String.t()) :: [{String.t(), DateTime.t(), float() | nil}]
  def leftovers(camera_id) do
    for {{^camera_id, label}, first_seen_at, score} <- :ets.tab2list(@table),
        do: {label, first_seen_at, score}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end
end
