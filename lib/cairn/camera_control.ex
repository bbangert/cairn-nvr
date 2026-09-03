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

  # The tombstone set lives in `:persistent_term`, not only in GenServer
  # state: `@table` is owned by this process, so a crash takes both the ETS
  # table and the state with it, and a plain restart would let a control
  # request racing the restart recreate a deleted id's overlay. A persistent
  # term survives the owning process, so `init/1` below reloads the same set
  # a restart would otherwise have dropped. Writing it on every
  # tombstone/prune/revive is fine because those are operator-paced (camera
  # deletes and re-creates), not a per-request hot path like `get/1`.
  @ptkey {__MODULE__, :tombstones}

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

  Answers `{:error, :removed}` for a tombstoned id — one `prune/1` dropped and
  `revive/1` has not brought back.
  """
  @spec set(String.t(), map()) :: control() | {:error, :removed}
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

  @doc """
  Removes control for cameras no longer configured (on reload), and tombstones
  every id it drops.

  A call, not a cast: this runs as a delete's `after_apply` inside the config
  server, and a queued cast could be handled *after* a same-id re-create's
  first writes and wipe them.
  """
  @spec prune([String.t()]) :: :ok
  def prune(known_camera_ids), do: GenServer.call(__MODULE__, {:prune, known_camera_ids})

  @doc """
  Clears an id's tombstone, so writes for it land again.

  A create's `after_commit` and `after_apply` (`Cairn.Cameras.create/1`),
  both — a re-created id is a camera again, and its overlay starts from the
  defaults `get/1` returns for an id with no row in the table. Idempotent, so
  the second call costs nothing on the ordinary path; see `create/1`'s
  comment for why it rides both. Also the `after_rollback` of a delete or a
  re-import: those tombstone inside the write closure, which the transaction
  does not undo.

  A call for the same reason `prune/1` is: it runs inside the config server,
  and a cast could be handled after the new camera's first writes — which
  would then have been refused.
  """
  @spec revive(String.t()) :: :ok
  def revive(camera_id), do: GenServer.call(__MODULE__, {:revive, camera_id})

  @doc """
  Tombstones an id whether or not it ever held a control row: `prune/1` can
  only mark the rows it drops, and a camera that never received a control
  write would otherwise be recreatable by a late one.
  """
  @spec tombstone(String.t()) :: :ok
  def tombstone(camera_id), do: GenServer.call(__MODULE__, {:tombstone, camera_id})

  @impl true
  # Seeded from the persistent term, not `MapSet.new()`: a restart after a
  # crash must come back refusing the same ids it refused before, or the
  # tombstone a caller observed would have quietly expired.
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{tombstoned: tombstones()}}
  end

  @impl true
  # Tombstoned ids are refused rather than written: a caller that checked the
  # camera exists (the HA control endpoint) and then writes is not serialized
  # with deletion, so a delete can commit and prune in between — and the late
  # write would recreate the overlay under a dead id, which a later camera
  # created under the same id would then inherit. Reads the persistent term
  # directly rather than `state.tombstoned`: they agree except in the window
  # right after a restart, and it is exactly that window this check exists to
  # close.
  def handle_call({:set, camera_id, attrs}, _from, state) do
    if MapSet.member?(tombstones(), camera_id) do
      {:reply, {:error, :removed}, state}
    else
      control = Map.merge(get(camera_id), Map.take(attrs, Map.keys(@defaults)))
      :ets.insert(@table, {camera_id, control})
      Phoenix.PubSub.broadcast(Cairn.PubSub, @topic, {:camera_control, camera_id, control})
      {:reply, control, state}
    end
  end

  def handle_call({:prune, known}, _from, state) do
    dropped =
      for {camera_id, _} <- :ets.tab2list(@table), camera_id not in known do
        :ets.delete(@table, camera_id)
        camera_id
      end

    {:reply, :ok, put_tombstones(state, MapSet.union(state.tombstoned, MapSet.new(dropped)))}
  end

  def handle_call({:tombstone, camera_id}, _from, state) do
    :ets.delete(@table, camera_id)
    {:reply, :ok, put_tombstones(state, MapSet.put(state.tombstoned, camera_id))}
  end

  def handle_call({:revive, camera_id}, _from, state) do
    {:reply, :ok, put_tombstones(state, MapSet.delete(state.tombstoned, camera_id))}
  end

  defp tombstones, do: :persistent_term.get(@ptkey, MapSet.new())

  # The one place `@ptkey` is written: every tombstone/prune/revive replaces
  # it wholesale, so it never drifts from `state.tombstoned`.
  defp put_tombstones(state, tombstoned) do
    :persistent_term.put(@ptkey, tombstoned)
    %{state | tombstoned: tombstoned}
  end
end
