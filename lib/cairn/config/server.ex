defmodule Cairn.Config.Server do
  @moduledoc """
  Holds the active `Cairn.Config`. Loads YAML at boot; `reload/0` re-reads,
  validates, diffs plugin groups and cameras against the running set and
  applies both diffs (start/stop/restart group and camera children). An
  invalid reload keeps the old config and returns the errors.

  Group children are applied before camera children: a group bakes its
  members' UDP ports into its argv, so it should be listening before the
  ffmpeg outputs feeding it come back.
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
    apply_group_diff = Keyword.get(opts, :apply_group_diff, &default_apply_group_diff/2)

    state = %{
      path: path,
      apply_diff: apply_diff,
      apply_group_diff: apply_group_diff,
      config: %Config{},
      warnings: [],
      errors: []
    }

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
        group_diff = diff_plugin_groups(state.config, new_config)
        diff = diff_cameras(state.config, new_config)
        # Before the diffs: newly spawned ports redirect logs into the (possibly
        # changed) data_dir, so its log subdir must already exist
        Cairn.DataDir.ensure!(new_config.data_dir)
        log_group_diff(group_diff)
        state.apply_group_diff.(group_diff, new_config)
        state.apply_diff.(diff, new_config)
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
    old_index = index_by_id(old.cameras)
    new_index = index_by_id(new.cameras)
    old_ids = MapSet.new(Map.keys(old_by_id))
    new_ids = MapSet.new(Map.keys(new_by_id))

    changed =
      for id <- MapSet.intersection(old_ids, new_ids),
          camera_changed?(
            old,
            new,
            {old_by_id[id], old_index[id]},
            {new_by_id[id], new_index[id]}
          ),
          do: id

    diff(old_ids, new_ids, changed)
  end

  @doc false
  @spec diff_plugin_groups(Config.t(), Config.t()) :: diff()
  def diff_plugin_groups(old, new) do
    old_by_name = Map.new(old.plugin_groups, &{&1.name, &1})
    new_by_name = Map.new(new.plugin_groups, &{&1.name, &1})
    old_names = MapSet.new(Map.keys(old_by_name))
    new_names = MapSet.new(Map.keys(new_by_name))

    changed =
      for name <- MapSet.intersection(old_names, new_names),
          old_by_name[name] != new_by_name[name],
          do: name

    diff(old_names, new_names, changed)
  end

  # A camera's UDP ports are positional, so moving in the `cameras:` list is
  # as much a restart as changing a field.
  defp camera_changed?(old, new, {old_cam, old_index}, {new_cam, new_index}) do
    old_cam != new_cam or old_index != new_index or
      Config.windows(old, old_cam) != Config.windows(new, new_cam)
  end

  defp index_by_id(cameras) do
    cameras |> Enum.with_index() |> Map.new(fn {cam, index} -> {cam.id, index} end)
  end

  defp diff(old_keys, new_keys, changed) do
    %{
      added: MapSet.difference(new_keys, old_keys) |> Enum.sort(),
      removed: MapSet.difference(old_keys, new_keys) |> Enum.sort(),
      changed: Enum.sort(changed)
    }
  end

  defp log_group_diff(%{added: [], removed: [], changed: []}), do: :ok

  defp log_group_diff(group_diff) do
    Logger.info(
      "config: plugin groups added=#{inspect(group_diff.added)} " <>
        "removed=#{inspect(group_diff.removed)} changed=#{inspect(group_diff.changed)}"
    )
  end

  defp default_apply_group_diff(group_diff, config) do
    Cairn.PluginGroupSupervisor.apply_diff(group_diff, config)
  end
end
