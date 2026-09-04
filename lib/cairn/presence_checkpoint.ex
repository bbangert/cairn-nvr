defmodule Cairn.PresenceCheckpoint do
  @moduledoc """
  `Cairn.EventCheckpoint`'s shape for the presence lane: a public named ETS
  table holding each tier-1 camera's active event, the qualifying
  `{zone, label}` keys present at that moment, the pid of the extractor
  writing its clip and the render-slot continuity state
  (`%{centers: ..., next: ...}` — the adopted extractor is still buffering
  the same sidecar, so slot centres AND the per-event slot watermark must
  survive with the row), owned outside the pool so the row survives a
  `Cairn.PresenceRecorder` crash and can be restored by its replacement
  (`Cairn.PresenceRecorder.init/1`).

  A separate table rather than a second kind of row in `cairn_active_events`,
  and the separation is load-bearing: `Cairn.CameraTracker.restore_checkpointed/0`
  starts a `Cairn.CameraTracker` for every camera with a row in that table, so
  a presence event checkpointed there would grow tier-2 machinery on a tier-1
  camera at the next tracker-pool restart.

  The row carries the extractor **pid** where the tracked lane's restore looks
  its extractor up in `Cairn.Registry` by `{:extractor, event_id}`. Both work
  for a real extractor; the pid also survives the one place the registry
  cannot be asked — a `Cairn.PresenceRecorder` whose extractor was injected for
  a test — and it needs no stale-read tolerance, since a dead pid answers
  `Process.alive?/1` directly. A pid from a previous VM cannot be read here:
  the table is created empty by this process, so it is destroyed with the node
  and with its own owner.

  Like the other runtime owners, it prunes against the application config
  server's published snapshot, and only on that server's broadcasts.
  """

  use GenServer

  @table :cairn_active_presence_events

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @typedoc "The recorder's present key: a zone id (`nil` = whole frame) and a label."
  @type present_key :: {String.t() | nil, String.t()}

  @spec put(String.t(), Cairn.Event.t(), [present_key()], pid() | nil, map()) :: true
  def put(camera_id, %Cairn.Event{} = event, keys, extractor, box_slots \\ %{}),
    do: :ets.insert(@table, {camera_id, event, keys, extractor, box_slots})

  @spec delete(String.t()) :: true
  def delete(camera_id), do: :ets.delete(@table, camera_id)

  @doc """
  One camera's checkpoint, or `nil`.

  A read and not a take, `Cairn.EventCheckpoint.get/1`'s rule: the row stands
  for as long as the event is open, and whoever ends it deletes it.
  """
  @spec get(String.t()) :: {Cairn.Event.t(), [present_key()], pid() | nil, map()} | nil
  def get(camera_id) do
    case :ets.lookup(@table, camera_id) do
      [{^camera_id, event, keys, extractor, box_slots}] -> {event, keys, extractor, box_slots}
      [] -> nil
    end
  end

  @spec all() :: [{String.t(), Cairn.Event.t(), [present_key()], pid() | nil, map()}]
  def all, do: :ets.tab2list(@table)

  @doc "Empties the table in one operation."
  @spec clear() :: true
  def clear, do: :ets.delete_all_objects(@table)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])
    Cairn.Config.Server.subscribe()
    {:ok, %{}}
  end

  # The table is public — writes come from the recorders — but the rows of a
  # camera that left the config have no recorder left to end them, so this
  # process drops them itself on the config change rather than being told to.
  # Only the application server's diffs: they name the snapshot this prunes
  # against (`t:Cairn.Config.Server.diff/0`).
  @impl true
  def handle_info({:config_changed, %{server: Cairn.Config.Server}}, state) do
    case Cairn.Config.Server.known_ids() do
      # No snapshot is not an empty fleet: nothing to prune against.
      nil ->
        :ok

      known ->
        for {camera_id, _event, _keys, _extractor, _slots} <- all(),
            not MapSet.member?(known, camera_id) do
          delete(camera_id)
        end
    end

    {:noreply, state}
  end

  def handle_info({:config_changed, _another_servers_diff}, state), do: {:noreply, state}
end
