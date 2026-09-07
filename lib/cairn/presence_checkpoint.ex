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
  and the separation is by row shape: this one carries the present keys and the
  slot state, that one the live tracks, and each is read back by exactly one
  restore path that knows how to. One table keyed by camera id could not hold
  both for a camera whose tier has just flipped, and a reader would have to
  discriminate on shape to find out which kind it had.

  The row carries the extractor **pid** where the tracked lane's restore looks
  its extractor up in `Cairn.Registry` by `{:extractor, event_id}`. Both work
  for a real extractor; the pid also survives the one place the registry
  cannot be asked — a `Cairn.PresenceRecorder` whose extractor was injected for
  a test — and it needs no stale-read tolerance, since a dead pid answers
  `Process.alive?/1` directly. A pid from a previous VM cannot be read here:
  the table is created empty by this process, so it is destroyed with the node
  and with its own owner.

  Reads, and an event owner's `delete/1`, go straight to the table; a `put/5`
  goes through this process, which drops one for a camera the published config
  no longer names. The table is `:public`: routing a write here is a convention
  the in-tree writers keep, not something the table enforces, and the prune
  ordering below rests on their keeping it. Like the other runtime owners it
  prunes on the application config server's broadcasts alone, against the
  membership that diff carries.

  Its callers outlive it. Every tier-1 `Cairn.PresenceRecorder` is a child of
  its own camera's tree, so a crash here — which takes the table with it,
  there being no heir — leaves them all running and still writing. So the
  window between that crash and the supervisor's restart is absorbed here
  rather than raising into them: a `put/5` that finds no process is dropped,
  a `get/1` that finds no table answers `nil`, a `delete/1` `:ok`. Every one
  of those is a state the callers already handle, because it is the state a
  camera with no open event is in — and a recorder restarting inside the
  window sweeps for a stranded extractor exactly as it does for a row that
  was never written (`Cairn.PresenceRecorder.sweep_stranded/1`).
  """

  use GenServer

  require Logger

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
    do: write_through(camera_id, {:put, camera_id, event, keys, extractor, box_slots})

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
      do: write_through(camera_id, {:put!, camera_id, event, keys, extractor, box_slots})
  end

  # Direct, unlike `put/5`: a delete only ever removes the row an owner of the
  # event is done with, so there is nothing for the existence check to stop
  # and nothing to order against the prune — which is itself deletes.
  @spec delete(String.t()) :: :ok
  def delete(camera_id) do
    if_table_lives(:ok, fn ->
      :ets.delete(@table, camera_id)
      :ok
    end)
  end

  @doc """
  One camera's checkpoint, or `nil`.

  A read and not a take, `Cairn.EventCheckpoint.get/1`'s rule: the row stands
  for as long as the event is open, and whoever ends it deletes it.
  """
  @spec get(String.t()) :: {Cairn.Event.t(), [present_key()], pid() | nil, map()} | nil
  def get(camera_id) do
    case if_table_lives([], fn -> :ets.lookup(@table, camera_id) end) do
      [{^camera_id, event, keys, extractor, box_slots}] -> {event, keys, extractor, box_slots}
      [] -> nil
    end
  end

  @spec all() :: [{String.t(), Cairn.Event.t(), [present_key()], pid() | nil, map()}]
  def all, do: if_table_lives([], fn -> :ets.tab2list(@table) end)

  @doc "Empties the table in one operation."
  @spec clear() :: :ok
  def clear do
    if_table_lives(:ok, fn ->
      :ets.delete_all_objects(@table)
      :ok
    end)
  end

  # The write goes through this process for the ordering the existence check
  # rests on, so it is also the one entry that can find no process at all.
  # Dropped, not raised: a row that never landed is a row the restore does not
  # find, which is the same state — and the same sweep — as a camera that had
  # nothing open.
  defp write_through(camera_id, message) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, reason ->
      Logger.debug(
        "camera #{camera_id}: presence checkpoint unavailable (#{inspect(reason)}); " <>
          "the write is dropped"
      )

      :ok
  end

  # `Cairn.PresenceLedger.if_table_lives/2`'s guard, for its reason: the table
  # can vanish between an `:ets.whereis/1` check and the operation, so the
  # rescue is needed either way.
  defp if_table_lives(absent, operation) do
    operation.()
  rescue
    ArgumentError -> absent
  end

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
  # camera's row comes back — a recorder's last writes can land after the
  # camera it belongs to has left the config.
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

  # Guarded like every other table op, and here it protects THIS process: a
  # write arriving in its own restart window — the table gone, the mailbox
  # already served — would otherwise raise inside the owner and take the
  # ledger with it (`:rest_for_one`), turning one crash into a loop for as
  # long as any recorder keeps checkpointing.
  defp write(camera_id, event, keys, extractor, slots) do
    if_table_lives(:ok, fn ->
      :ets.insert(@table, {camera_id, event, keys, extractor, slots})
      :ok
    end)
  end

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
