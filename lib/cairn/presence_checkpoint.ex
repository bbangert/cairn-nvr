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

  Reads go straight to the table; writes go through this process, which drops
  one for a camera the published config no longer names. Like the other
  runtime owners it prunes on the application config server's broadcasts
  alone, against the membership that diff carries.
  """

  use GenServer

  @table :cairn_active_presence_events

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @typedoc "The recorder's present key: a zone id (`nil` = whole frame) and a label."
  @type present_key :: {String.t() | nil, String.t()}

  @doc """
  Writes one camera's checkpoint, or drops the write when the published
  config does not name the camera.

  A call rather than a cast, `Cairn.EventCheckpoint.put/3`'s rule: the row is
  read back on restore, and it is written once per event start plus a
  throttled refresh.
  """
  @spec put(String.t(), Cairn.Event.t(), [present_key()], pid() | nil, map()) :: :ok
  def put(camera_id, %Cairn.Event{} = event, keys, extractor, box_slots \\ %{}),
    do: GenServer.call(__MODULE__, {:put, camera_id, event, keys, extractor, box_slots})

  # `put/5` without the existence check, for the suites whose camera exists
  # only as a fixture and never in a fleet config. Same mailbox and same
  # table: the ordering the check depends on is not weakened, only the check
  # itself is skipped. Compiled only in :test — `:erpc` and the HA API can
  # reach any exported function, and an unchecked write is not a surface to
  # leave on a running node.
  if Mix.env() == :test do
    @doc false
    @spec put!(String.t(), Cairn.Event.t(), [present_key()], pid() | nil, map()) :: :ok
    def put!(camera_id, %Cairn.Event{} = event, keys, extractor, box_slots \\ %{}),
      do: GenServer.call(__MODULE__, {:put!, camera_id, event, keys, extractor, box_slots})
  end

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

  # The existence check runs here, in the mailbox that also handles the prune,
  # and that is the whole ordering: the config server publishes its snapshot
  # before it applies and broadcasts after, so a write handled after the
  # publish finds no id and is dropped, and one handled before is deleted by
  # the prune the broadcast that follows triggers. Without it a deleted
  # camera's row comes back — a recorder arming its post window outlives
  # `retire/1` and checkpoints once more on its way out.
  @impl true
  def handle_call({:put, camera_id, event, keys, extractor, slots}, _from, state) do
    if known?(camera_id), do: write(camera_id, event, keys, extractor, slots)
    {:reply, :ok, state}
  end

  if Mix.env() == :test do
    def handle_call({:put!, camera_id, event, keys, extractor, slots}, _from, state) do
      write(camera_id, event, keys, extractor, slots)
      {:reply, :ok, state}
    end
  end

  defp write(camera_id, event, keys, extractor, slots),
    do: :ets.insert(@table, {camera_id, event, keys, extractor, slots})

  # No snapshot is not an empty fleet: a server that has published none (an
  # unnamed one, or one still in `init/1`) cannot say which cameras exist, so
  # it cannot drop a write.
  defp known?(camera_id) do
    case Cairn.Config.Server.known_ids() do
      nil -> true
      known -> MapSet.member?(known, camera_id)
    end
  end

  # The rows of a camera that left the config have no recorder left to end
  # them, so this process drops them itself on the config change rather than
  # being told to. Only the application server's diffs: this table holds that
  # server's fleet (`t:Cairn.Config.Server.diff/0`).
  @impl true
  def handle_info(
        {:config_changed, %{server: Cairn.Config.Server, known: %MapSet{} = known}},
        state
      ) do
    for {camera_id, _event, _keys, _extractor, _slots} <- all(),
        not MapSet.member?(known, camera_id) do
      delete(camera_id)
    end

    {:noreply, state}
  end

  # Another server's diff, or one without the membership this owner prunes on.
  def handle_info({:config_changed, _other}, state), do: {:noreply, state}
end
