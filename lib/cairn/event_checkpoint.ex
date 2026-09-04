defmodule Cairn.EventCheckpoint do
  @moduledoc """
  Public named ETS table holding a snapshot of each camera's active event and
  the tracks live at that moment, owned by a process outside the trackers so
  the data survives a `Cairn.CameraTracker` crash. A replacement tracker
  restores its own camera's row from here (`get/1`) — re-attaching to a
  still-running extractor or dropping an orphaned entry, and ending every
  restored track (`:host_restart`), since the tracker element those tracks
  belonged to knows nothing of the replacement.

  The tracks are the snapshot the batch carried (`checkpoint_tracks/1` on the
  camera's tracker core), not something the writer derived: the tracking lives
  in the pipeline now, and this row is the only place it crosses into
  something that outlives one.

  Reads, and an event owner's `delete/1`, go straight to the table; a `put/3`
  goes through this process, which drops one for a camera the published config
  no longer names. The table is `:public`: routing a write here is a convention
  the in-tree writers keep, not something the table enforces, and the prune
  ordering below rests on their keeping it. Like the other runtime owners it
  prunes on the application config server's broadcasts alone, against the
  membership that diff carries.
  """

  use GenServer

  @table :cairn_active_events

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Writes one camera's checkpoint, or drops the write when the published
  config does not name the camera.

  A call rather than a cast: a tracker restoring or handing over reads the
  row back, and the write rate is one per event start plus a throttled
  refresh (`Cairn.CameraTracker`), so serializing on this mailbox costs
  nothing.
  """
  @spec put(String.t(), Cairn.Event.t(), [Cairn.Track.t()]) :: :ok
  def put(camera_id, %Cairn.Event{} = event, tracks \\ []),
    do: GenServer.call(__MODULE__, {:put, camera_id, event, tracks})

  # `put/3` without the existence check, for the suites whose camera exists
  # only as a fixture and never in a fleet config. Same mailbox and same
  # table: the ordering the check depends on is not weakened, only the check
  # itself is skipped. Compiled only in :test — `:erpc` and the HA API can
  # reach any exported function, and an unchecked write is not a surface to
  # leave on a running node.
  if Mix.env() == :test do
    @doc false
    @spec put!(String.t(), Cairn.Event.t(), [Cairn.Track.t()]) :: :ok
    def put!(camera_id, %Cairn.Event{} = event, tracks \\ []),
      do: GenServer.call(__MODULE__, {:put!, camera_id, event, tracks})
  end

  # Direct, unlike `put/3`: a delete only ever removes the row an owner of the
  # event is done with, so there is nothing for the existence check to stop
  # and nothing to order against the prune — which is itself deletes.
  @spec delete(String.t()) :: true
  def delete(camera_id), do: :ets.delete(@table, camera_id)

  @doc """
  One camera's checkpoint, or `nil`.

  A read and not a take: re-attaching to a live extractor leaves the row in
  place, because the event is still open and the *next* restore must find it.
  Whoever ends the event deletes it (`delete/1`).
  """
  @spec get(String.t()) :: {Cairn.Event.t(), [Cairn.Track.t()]} | nil
  def get(camera_id) do
    case :ets.lookup(@table, camera_id) do
      [{^camera_id, event, tracks}] -> {event, tracks}
      [] -> nil
    end
  end

  @spec all() :: [{String.t(), Cairn.Event.t(), [Cairn.Track.t()]}]
  def all, do: :ets.tab2list(@table)

  @doc """
  Empties the table in one operation.

  Deleting row by row off `all/0` is not atomic: anything inserting between
  the read and the deletes survives.
  """
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
  # camera's row comes back — the tracker outlives the camera's removal and
  # checkpoints once more on its way out.
  @impl true
  def handle_call({:put, camera_id, event, tracks}, _from, state) do
    if known?(camera_id), do: write(camera_id, event, tracks)
    {:reply, :ok, state}
  end

  if Mix.env() == :test do
    def handle_call({:put!, camera_id, event, tracks}, _from, state) do
      write(camera_id, event, tracks)
      {:reply, :ok, state}
    end
  end

  defp write(camera_id, event, tracks), do: :ets.insert(@table, {camera_id, event, tracks})

  # No snapshot is not an empty fleet: a server that has published none (an
  # unnamed one, or one still in `init/1`) cannot say which cameras exist, so
  # it cannot drop a write.
  defp known?(camera_id) do
    case Cairn.Config.Server.known_ids() do
      nil -> true
      known -> MapSet.member?(known, camera_id)
    end
  end

  # The rows of a camera that left the config have no tracker left to end
  # them, so this process drops them itself on the config change rather than
  # being told to. Only the application server's diffs: this table holds that
  # server's fleet (`t:Cairn.Config.Server.diff/0`).
  @impl true
  def handle_info(
        {:config_changed, %{server: Cairn.Config.Server, known: %MapSet{} = known}},
        state
      ) do
    for {camera_id, _event, _tracks} <- all(), not MapSet.member?(known, camera_id) do
      delete(camera_id)
    end

    {:noreply, state}
  end

  # Another server's diff, or one without the membership this owner prunes on.
  def handle_info({:config_changed, _other}, state), do: {:noreply, state}
end
