defmodule Cairn.CameraStatus do
  @moduledoc """
  ETS-backed per-camera runtime status (`:connecting | :running | :backoff |
  :stalled | :transcode_unavailable`) plus probe results (Phase 8), with
  PubSub change notifications on `"cameras:status"`.

  Written by `Cairn.FFmpegPort` / the watchdog; read by the dashboard and
  config LiveViews.
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

  @spec merge(String.t(), map()) :: :ok
  def merge(camera_id, attrs) when is_map(attrs) do
    GenServer.cast(__MODULE__, {:merge, camera_id, attrs})
  end

  @spec get(String.t()) :: map()
  def get(camera_id) do
    case :ets.lookup(@table, camera_id) do
      [{^camera_id, info}] -> info
      [] -> %{status: :unknown, probe: nil}
    end
  end

  @spec all() :: %{String.t() => map()}
  def all, do: Map.new(:ets.tab2list(@table))

  @doc "Removes status for cameras no longer configured (on reload)."
  @spec prune([String.t()]) :: :ok
  def prune(known_camera_ids), do: GenServer.cast(__MODULE__, {:prune, known_camera_ids})

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:merge, camera_id, attrs}, state) do
    info = Map.merge(get(camera_id), attrs)
    :ets.insert(@table, {camera_id, info})
    Phoenix.PubSub.broadcast(Cairn.PubSub, @topic, {:camera_status, camera_id, info})
    {:noreply, state}
  end

  def handle_cast({:prune, known}, state) do
    for {camera_id, _} <- :ets.tab2list(@table), camera_id not in known do
      :ets.delete(@table, camera_id)
    end

    {:noreply, state}
  end
end
