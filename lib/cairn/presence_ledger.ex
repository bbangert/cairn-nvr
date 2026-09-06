defmodule Cairn.PresenceLedger do
  @moduledoc """
  The announced set: every `{camera, zone, label}` a `presence_started` went
  out for and no `presence_cleared` has yet answered. `zone` is a zone id, or
  `nil` for whole-frame presence on a camera with no zones — the same key
  `Cairn.PresenceAggregator` folds on, so clearing one zone's state deletes
  that row alone and never the same label's rows under other zones.

  Exists for one reason — the every-started-gets-a-cleared invariant must
  survive an aggregator crash. Presence is edge-only and unpersisted, so a
  restarted aggregator that starts blank leaves every client that tracked
  the edges stuck at "present" forever; instead its `init` reads this table
  and clears what the dead process had announced. The table therefore lives
  outside every camera's tree: `Cairn.PresenceSupervisor` owns it at node
  level, so no aggregator's crash — and no camera's stop — can take it down,
  and an aggregator restarting finds the set its predecessor left. A crash of
  this process loses the set; so does the VM — that is the depth of guarantee
  an in-memory ledger buys, and the moduledoc of `Cairn.PresenceAggregator`
  states the recovery bargain it serves.

  Writes come only from aggregators, on the same process that broadcasts,
  ordered for at-least-once recovery: the row is inserted BEFORE the
  started may go out and deleted only AFTER the cleared has — a crash
  between either pair costs a duplicate cleared, never a missing one.
  """

  use GenServer

  @table __MODULE__

  @type zone :: String.t() | nil

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Record an announced `{camera, zone, label}` — called before the started broadcast."
  @spec announced(String.t(), zone(), String.t(), DateTime.t(), float() | nil) :: true
  def announced(camera_id, zone, label, first_seen_at, score) do
    :ets.insert(@table, {{camera_id, zone, label}, first_seen_at, score})
  end

  @doc "The matching cleared went out."
  @spec cleared(String.t(), zone(), String.t()) :: true
  def cleared(camera_id, zone, label), do: :ets.delete(@table, {camera_id, zone, label})

  @doc """
  One camera's announced keys: the rows a dead aggregator left, and the
  answer `Cairn.PresenceRecorder` restores and segments against.

  A read, never a take — the aggregator's restart is what clears these.

  `match_object/2` rather than `tab2list/1` and a filter: the key is
  `{camera, zone, label}`, so a partially bound key is still a scan, but one
  that happens inside ETS instead of copying every other camera's rows into
  the caller. It is read per recorder start, per `max_event` boundary and
  per open-retry tick, not per frame.
  """
  @spec leftovers(String.t()) :: [{zone(), String.t(), DateTime.t(), float() | nil}]
  def leftovers(camera_id) do
    for {{_camera_id, zone, label}, first_seen_at, score} <-
          :ets.match_object(@table, {{camera_id, :_, :_}, :_, :_}),
        do: {zone, label, first_seen_at, score}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end
end
