defmodule Cairn.Config.Server do
  @moduledoc """
  Holds the active `Cairn.Config`. Loads YAML at boot; `reload/0` re-reads,
  validates, diffs cameras against the running set and applies the diff
  (start/stop/restart camera children). An invalid reload keeps the old
  config and returns the errors.
  """

  use GenServer

  require Logger

  alias Cairn.Config

  @type diff :: %{added: [String.t()], removed: [String.t()], changed: [String.t()]}

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec get(GenServer.server()) :: Config.t()
  def get(server \\ __MODULE__), do: GenServer.call(server, :get)

  @spec camera(String.t()) :: {:ok, Config.Camera.t()} | :error
  def camera(camera_id, server \\ __MODULE__) do
    case Enum.find(get(server).cameras, &(&1.id == camera_id)) do
      nil -> :error
      cam -> {:ok, cam}
    end
  end

  @spec data_dir(GenServer.server()) :: String.t()
  def data_dir(server \\ __MODULE__), do: get(server).data_dir

  @doc "Configured HA integration token, or `nil` when the integration is disabled."
  @spec ha_token(GenServer.server()) :: String.t() | nil
  def ha_token(server \\ __MODULE__), do: get(server).ha_token

  @doc "Warnings and errors from the last load/reload attempt (for the UI)."
  @spec last_load(GenServer.server()) :: %{warnings: [String.t()], errors: [String.t()]}
  def last_load(server \\ __MODULE__), do: GenServer.call(server, :last_load)

  @spec reload(GenServer.server()) ::
          {:ok, diff(), [String.t()]} | {:error, [String.t()]}
  def reload(server \\ __MODULE__), do: GenServer.call(server, :reload, 30_000)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path) || Config.default_path()
    apply_diff = Keyword.get(opts, :apply_diff, &Cairn.CameraSupervisor.apply_diff/2)

    state = %{path: path, apply_diff: apply_diff, config: %Config{}, warnings: [], errors: []}

    case Config.load(path) do
      {:ok, config, warnings} ->
        Enum.each(warnings, &Logger.warning("config: #{&1}"))
        Cairn.DataDir.ensure!(config.data_dir)
        {:ok, %{state | config: config, warnings: warnings}}

      {:error, errors} ->
        Enum.each(errors, &Logger.error("config: #{&1}"))
        Logger.error("config: starting with empty defaults (no cameras)")
        Cairn.DataDir.ensure!(state.config.data_dir)
        {:ok, %{state | errors: errors}}
    end
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.config, state}

  def handle_call(:last_load, _from, state) do
    {:reply, %{warnings: state.warnings, errors: state.errors}, state}
  end

  def handle_call(:reload, _from, state) do
    case Config.load(state.path) do
      {:ok, new_config, warnings} ->
        diff = diff_cameras(state.config, new_config)
        state.apply_diff.(diff, new_config)
        Cairn.DataDir.ensure!(new_config.data_dir)
        state = %{state | config: new_config, warnings: warnings, errors: []}
        {:reply, {:ok, diff, warnings}, state}

      {:error, errors} ->
        {:reply, {:error, errors}, %{state | errors: errors}}
    end
  end

  @doc false
  @spec diff_cameras(Config.t(), Config.t()) :: diff()
  def diff_cameras(old, new) do
    old_by_id = Map.new(old.cameras, &{&1.id, &1})
    new_by_id = Map.new(new.cameras, &{&1.id, &1})
    old_ids = MapSet.new(Map.keys(old_by_id))
    new_ids = MapSet.new(Map.keys(new_by_id))

    changed =
      for id <- MapSet.intersection(old_ids, new_ids),
          old_by_id[id] != new_by_id[id] or
            Config.windows(old, old_by_id[id]) != Config.windows(new, new_by_id[id]),
          do: id

    %{
      added: MapSet.difference(new_ids, old_ids) |> Enum.sort(),
      removed: MapSet.difference(old_ids, new_ids) |> Enum.sort(),
      changed: Enum.sort(changed)
    }
  end
end
