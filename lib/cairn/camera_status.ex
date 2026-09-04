defmodule Cairn.CameraStatus do
  @moduledoc """
  ETS-backed per-camera runtime status (`:connecting | :running | :backoff |
  :stalled | :transcode_unavailable`) plus probe results (Phase 8) and the
  last detector health reported for the camera, with PubSub change
  notifications on `"cameras:status"`.

  Written by `Cairn.PipelineOwner` (the lifecycle, watchdog included) and, for
  a bridge camera's own connect/backoff, by `Cairn.FFmpegPort` — the split is
  stated in the owner's moduledoc. The detector's health, which the in-VM
  native block reports with no process of its own, comes from
  `Cairn.Native.Status`. Read by the dashboard and config LiveViews and by the
  HA API.

  This process owns the table: every write above goes through it, and it is
  also what prunes. It subscribes to the config topic and drops the rows of
  cameras the new config no longer names, in its own callback — nobody hands
  it a list of ids, and a camera that comes back starts at `:unknown`. It
  prunes against the application config server's published snapshot, and only
  on that server's broadcasts.
  """

  use GenServer

  @table __MODULE__
  @topic "cameras:status"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Broadcasts `{:camera_status, camera_id, info}` on change."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Cairn.PubSub, @topic)

  @spec set(String.t(), atom()) :: :ok
  def set(camera_id, status), do: merge(camera_id, %{status: status})

  @spec set_probe(String.t(), map() | {:error, term()}) :: :ok
  def set_probe(camera_id, probe), do: merge(camera_id, %{probe: probe})

  @doc """
  Stores the detector's own last reported state, in the `plugin.status`
  shape the external contract defined: string-keyed and JSON-safe, because
  it is served as JSON. The key name outlives the plugin path it came from.
  """
  @spec set_plugin_status(String.t(), map() | nil) :: :ok
  def set_plugin_status(camera_id, status), do: merge(camera_id, %{plugin_status: status})

  @spec merge(String.t(), map()) :: :ok
  def merge(camera_id, attrs) when is_map(attrs) do
    GenServer.cast(__MODULE__, {:merge, camera_id, attrs})
  end

  @spec get(String.t()) :: map()
  def get(camera_id) do
    case :ets.lookup(@table, camera_id) do
      [{^camera_id, info}] -> info
      [] -> unknown()
    end
  rescue
    # the table is gone between an owner crash and its restart. Checking
    # `:ets.whereis/1` first would not help: it is not atomic with the lookup.
    # A reader (dashboard, HA API) lands in that window and sees :unknown
    # rather than crashing — same treatment as `Cairn.StreamEpochs.current/1`.
    ArgumentError -> unknown()
  end

  defp unknown, do: %{status: :unknown, probe: nil, plugin_status: nil}

  @spec all() :: %{String.t() => map()}
  def all, do: Map.new(:ets.tab2list(@table))

  # One camera's row, dropped. The config change is what drops rows in
  # production; this is for suites whose camera exists only as a fixture and
  # would otherwise leave its status in the shared table.
  @doc false
  @spec delete(String.t()) :: :ok
  def delete(camera_id), do: GenServer.call(__MODULE__, {:delete, camera_id})

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    Cairn.Config.Server.subscribe()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:delete, camera_id}, _from, state) do
    :ets.delete(@table, camera_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:merge, camera_id, attrs}, state) do
    info = Map.merge(get(camera_id), attrs)
    :ets.insert(@table, {camera_id, info})
    # local_broadcast, not broadcast: the backing table is a node-local named
    # ETS table, so a remote subscriber could never read what it was told
    # about — and plugin status arrives at line rate, one message per member.
    Phoenix.PubSub.local_broadcast(Cairn.PubSub, @topic, {:camera_status, camera_id, info})
    {:noreply, state}
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
  # unnamed one, or one still in `init/1`) cannot say which cameras exist, and
  # pruning against nothing would empty the table.
  defp prune(nil), do: :ok

  defp prune(known) do
    for {camera_id, _} <- :ets.tab2list(@table), not MapSet.member?(known, camera_id) do
      :ets.delete(@table, camera_id)
    end

    :ok
  end
end
