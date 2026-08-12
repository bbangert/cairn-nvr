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
  """
  @spec set(String.t(), map()) :: control()
  def set(camera_id, attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:set, camera_id, normalize(attrs)})
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

  @doc "Removes control for cameras no longer configured (on reload)."
  @spec prune([String.t()]) :: :ok
  def prune(known_camera_ids), do: GenServer.cast(__MODULE__, {:prune, known_camera_ids})

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:set, camera_id, attrs}, _from, state) do
    control = Map.merge(get(camera_id), Map.take(attrs, Map.keys(@defaults)))
    :ets.insert(@table, {camera_id, control})
    Phoenix.PubSub.broadcast(Cairn.PubSub, @topic, {:camera_control, camera_id, control})
    {:reply, control, state}
  end

  @impl true
  def handle_cast({:prune, known}, state) do
    for {camera_id, _} <- :ets.tab2list(@table), camera_id not in known do
      :ets.delete(@table, camera_id)
    end

    {:noreply, state}
  end
end
