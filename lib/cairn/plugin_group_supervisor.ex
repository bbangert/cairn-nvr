defmodule Cairn.PluginGroupSupervisor do
  @moduledoc """
  DynamicSupervisor over plugin group processes (`Cairn.PluginGroupPort`).

  A group is a single process, so it sits directly under this supervisor.
  Only groups with members are started — a group nothing references has
  nothing to serve. `sync/1` reconciles running groups against a config;
  `apply_diff/2` applies a reload diff, restarting groups whose command (a
  profile's model flags included, expanded into it at config load), profile
  or membership (ids, ports, score floors) changed.
  """

  use DynamicSupervisor

  require Logger

  alias Cairn.Config

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Starts all groups from `config` that have members and are not running."
  @spec sync(Config.t()) :: :ok
  def sync(%Config{} = config) do
    if Application.get_env(:cairn, :start_cameras, true) do
      do_sync(config)
    else
      :ok
    end
  end

  defp do_sync(config) do
    running = MapSet.new(Cairn.Registry.ids_for_role(:plugin_group))
    wanted = Enum.reject(config.plugin_groups, &(&1.members == []))

    Enum.each(MapSet.difference(running, MapSet.new(wanted, & &1.name)), &stop_group/1)

    Enum.each(wanted, fn group ->
      if MapSet.member?(running, group.name) do
        refresh_group(config, group)
      else
        start_group(config, group)
      end
    end)
  end

  @doc """
  Applies a `Cairn.Config.Server` reload diff against `new_config`.

  A group diff's `refreshed` list is always empty, and this function would
  ignore it either way: `sync/1` already hands every surviving group the new
  config unconditionally, and it has to. `diff_plugin_groups/2` compares
  groups, while what a refresh carries is the *member cameras'* host-side
  fields — those move without the group itself changing at all, so nothing in
  this diff could single them out.
  """
  @spec apply_diff(Config.Server.diff(), Config.t()) :: :ok
  def apply_diff(diff, %Config{} = new_config) do
    Enum.each(diff.removed ++ diff.changed, &stop_group/1)
    sync(new_config)
  end

  @spec start_group(Config.t(), Config.PluginGroup.t()) :: DynamicSupervisor.on_start_child()
  def start_group(%Config{} = config, group) do
    spec = {Cairn.PluginGroupPort, group: group, config: config}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("plugin group #{group.name}: failed to start: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Hands a still-running group the new config.

  A reload that changes the group restarts it; one that only changes camera
  fields the argv never carried (the `post` and `max` windows, the tracking
  bounds, the `track:` / `record:` tiers, retention) leaves it running, and it
  would otherwise keep routing detections with the pre-reload camera structs
  and policies. `pre` is deliberately not in that list: it restarts the member
  camera (ring sized at tree init), not this group.
  """
  @spec refresh_group(Config.t(), Config.PluginGroup.t()) :: :ok
  def refresh_group(%Config{} = config, group) do
    case Cairn.Registry.whereis(group.name, :plugin_group) do
      nil -> :ok
      pid -> Cairn.PluginGroupPort.refresh(pid, group, config)
    end
  end

  @spec stop_group(String.t()) :: :ok
  def stop_group(group_name) do
    case Cairn.Registry.whereis(group_name, :plugin_group) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        Cairn.Registry.await_unregistered(group_name, :plugin_group)
    end
  end
end
