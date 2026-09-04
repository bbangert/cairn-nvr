defmodule Cairn.CameraControl do
  @moduledoc """
  ETS-backed per-camera runtime control overlay (mirrors `Cairn.CameraStatus`).

  Holds `detection_enabled`, `recording_enabled` and an optional `min_score`
  override per camera. Values default to "on / no override" so behavior is
  identical to config until Home Assistant sets something. Changes broadcast
  `{:camera_control, camera_id, control}` on `"cameras:control"`.

  `get/1` reads the ETS table directly (hot path: the detect branch's
  `Cairn.Pipeline.ObservationStamper` reads it per buffer and
  `Cairn.CameraTracker` per batch); writes go through the GenServer owner.

  This process owns the table: every write goes through it, and it is also
  what prunes. It subscribes to the config topic and drops the rows of
  cameras the new config no longer names, in its own callback, and refuses a
  write for a camera the published config does not name (`set/2`). It prunes
  and checks against the application config server's published snapshot, and
  prunes only on that server's broadcasts.
  """

  use GenServer

  @table __MODULE__
  @topic "cameras:control"
  @defaults %{detection_enabled: true, recording_enabled: true, min_score: nil}

  @type control :: %{
          detection_enabled: boolean(),
          recording_enabled: boolean(),
          min_score: float() | nil
        }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Broadcasts `{:camera_control, camera_id, control}` on change."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Cairn.PubSub, @topic)

  @doc "Current control overlay for a camera (defaults when never set)."
  @spec get(String.t()) :: control()
  def get(camera_id) do
    case :ets.lookup(@table, camera_id) do
      [{^camera_id, control}] -> control
      [] -> @defaults
    end
  end

  @spec all() :: %{String.t() => control()}
  def all, do: Map.new(:ets.tab2list(@table))

  @known_keys ~w(detection_enabled recording_enabled min_score)a
  @string_keys Map.new(@known_keys, &{Atom.to_string(&1), &1})

  @doc """
  Merges `attrs` (a subset of `:detection_enabled`, `:recording_enabled`,
  `:min_score`) into a camera's control and returns the new control. Accepts
  either atom or string keys; unknown keys are ignored.

  `{:error, :unknown_camera}` when the published config does not name the
  camera — the overlay is only meaningful for a camera that exists.
  """
  @spec set(String.t(), map()) :: control() | {:error, :unknown_camera}
  def set(camera_id, attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:set, camera_id, normalize(attrs)})
  end

  # `set/2` without the existence check, for the suites whose camera exists
  # only as a pipeline fixture and never in a fleet config. Same mailbox and
  # same table: the ordering `set/2`'s check depends on is not weakened, only
  # the check itself is skipped. Compiled only in :test — `:erpc` and the HA
  # API can reach any exported function, and an unchecked write is not a
  # surface to leave on a running node.
  if Mix.env() == :test do
    @doc false
    @spec put(String.t(), map()) :: control()
    def put(camera_id, attrs) when is_map(attrs) do
      GenServer.call(__MODULE__, {:put, camera_id, normalize(attrs)})
    end
  end

  # Accept string- or atom-keyed input, keeping only the known keys. Only maps
  # a fixed set of strings to atoms (never String.to_atom on arbitrary input).
  defp normalize(attrs) do
    Enum.reduce(attrs, %{}, fn
      {k, v}, acc when is_atom(k) and k in @known_keys ->
        Map.put(acc, k, v)

      {k, v}, acc when is_binary(k) ->
        case Map.fetch(@string_keys, k) do
          {:ok, atom} -> Map.put(acc, atom, v)
          :error -> acc
        end

      _kv, acc ->
        acc
    end)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    Cairn.Config.Server.subscribe()
    {:ok, %{}}
  end

  # The existence check runs here, in the mailbox that also handles the prune,
  # and that is the whole ordering: the config server publishes its snapshot
  # before it applies and broadcasts after, so a write handled after the
  # publish finds no id and is refused, and one handled before is deleted by
  # the prune the broadcast that follows triggers. Nothing is marked, nothing
  # needs reviving, and a check made outside this process could be neither.
  @impl true
  def handle_call({:set, camera_id, attrs}, _from, state) do
    if known?(camera_id),
      do: {:reply, write(camera_id, attrs), state},
      else: {:reply, {:error, :unknown_camera}, state}
  end

  if Mix.env() == :test do
    def handle_call({:put, camera_id, attrs}, _from, state) do
      {:reply, write(camera_id, attrs), state}
    end
  end

  defp write(camera_id, attrs) do
    control = Map.merge(get(camera_id), Map.take(attrs, Map.keys(@defaults)))
    :ets.insert(@table, {camera_id, control})
    Phoenix.PubSub.broadcast(Cairn.PubSub, @topic, {:camera_control, camera_id, control})
    control
  end

  # Only the application server's diffs: they name the snapshot this prunes
  # against (`t:Cairn.Config.Server.diff/0`).
  @impl true
  def handle_info({:config_changed, %{server: Cairn.Config.Server}}, state) do
    prune(Cairn.Config.Server.known_ids())
    {:noreply, state}
  end

  def handle_info({:config_changed, _another_servers_diff}, state), do: {:noreply, state}

  # No snapshot is not an empty fleet: a server that has published none (an
  # unnamed one, or one still in `init/1`) cannot say which cameras exist, so
  # it can neither refuse a write nor empty the table.
  defp known?(camera_id) do
    case Cairn.Config.Server.known_ids() do
      nil -> true
      known -> MapSet.member?(known, camera_id)
    end
  end

  defp prune(nil), do: :ok

  defp prune(known) do
    for {camera_id, _} <- :ets.tab2list(@table), not MapSet.member?(known, camera_id) do
      :ets.delete(@table, camera_id)
    end

    :ok
  end
end
