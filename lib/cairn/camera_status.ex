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
  `Cairn.Native.Status`. Read by the dashboard and cameras LiveViews and by
  the HA API — `CairnWeb.ConfigLive` shows globals and the import marker
  only, not per-camera status.
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

  @doc """
  Removes status for cameras no longer configured (on reload).

  A call, not a cast: this runs as a delete's `after_apply` inside the config
  server, and a queued cast could be handled *after* a same-id re-create's
  first writes and wipe them.
  """
  @spec prune([String.t()]) :: :ok
  def prune(known_camera_ids), do: GenServer.call(__MODULE__, {:prune, known_camera_ids})

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
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

  @impl true
  def handle_call({:prune, known}, _from, state) do
    for {camera_id, _} <- :ets.tab2list(@table), camera_id not in known do
      :ets.delete(@table, camera_id)
    end

    {:reply, :ok, state}
  end
end
