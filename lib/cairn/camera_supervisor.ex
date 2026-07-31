defmodule Cairn.CameraSupervisor do
  @moduledoc """
  DynamicSupervisor over per-camera supervision trees (`Cairn.Camera`).

  Camera UDP port allocation is positional (see `Cairn.UDPPorts`), so
  start/stop take the camera's index in the config list. `sync/1` reconciles
  running cameras against a config; `apply_diff/2` applies a reload diff,
  restarting the cameras it marks `changed` and handing the new config to the
  plugin ports of the ones it marks `refreshed` (`Cairn.PluginPort.refresh/3`).
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

  @doc "Starts all cameras from `config` that are not already running."
  @spec sync(Config.t()) :: :ok
  def sync(%Config{} = config) do
    if Application.get_env(:cairn, :start_cameras, true) do
      do_sync(config)
    else
      :ok
    end
  end

  defp do_sync(config) do
    running = MapSet.new(Cairn.Registry.ids_for_role(:camera))
    wanted = MapSet.new(config.cameras, & &1.id)

    Enum.each(MapSet.difference(running, wanted), &stop_camera/1)

    config.cameras
    |> Enum.with_index()
    |> Enum.each(fn {cam, index} ->
      unless MapSet.member?(running, cam.id), do: start_camera(config, cam, index)
    end)
  end

  @doc """
  Applies a `Cairn.Config.Server` reload diff against `new_config`.

  A `refreshed` camera is one the stop+sync above deliberately left running:
  its plugin port is still the pre-reload OS process, still holding the
  pre-reload policy, so it is handed the new one instead of being restarted.
  """
  @spec apply_diff(Config.Server.diff(), Config.t()) :: :ok
  # The full diff shape is matched in the head: all four keys are the
  # contract (`Cairn.Config.Server.diff/0`), and a caller handing a partial
  # map should fail here, loudly, not by KeyError three lines in — and not be
  # silently tolerated with defaults, which would let a malformed diff skip
  # work it named.
  def apply_diff(
        %{removed: removed, changed: changed, refreshed: refreshed, added: _},
        %Config{} = new_config
      ) do
    Enum.each(removed ++ changed, &stop_camera/1)
    sync(new_config)
    Enum.each(refreshed, &refresh_camera(new_config, &1))
  end

  @doc """
  Hands a still-running camera's plugin port the new camera and config.

  Three ways this is a no-op, all of them ordinary and all of them a `nil`
  from `whereis`: a `{:group, _}` camera registers no `:plugin` of its own
  (`Cairn.PluginGroupSupervisor` refreshes the shared group process that
  serves it), a camera with no `plugin:` at all has nothing to refresh, and a
  camera that is not running has no process to tell. None is an error. The
  config lookup guards the fourth, which a diff cannot produce: an id
  `config` does not carry.
  """
  @spec refresh_camera(Config.t(), String.t()) :: :ok
  def refresh_camera(%Config{} = config, camera_id) do
    with pid when is_pid(pid) <- Cairn.Registry.whereis(camera_id, :plugin),
         %Config.Camera{} = cam <- Enum.find(config.cameras, &(&1.id == camera_id)) do
      Cairn.PluginPort.refresh(pid, cam, config)
    else
      _absent -> :ok
    end
  end

  @spec start_camera(Config.t(), Config.Camera.t(), non_neg_integer()) ::
          DynamicSupervisor.on_start_child()
  def start_camera(%Config{} = config, cam, index) do
    spec = {Cairn.Camera, camera: cam, index: index, config: config}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("camera #{cam.id}: failed to start: #{inspect(reason)}")
        error
    end
  end

  @spec stop_camera(String.t()) :: :ok
  def stop_camera(camera_id) do
    case Cairn.Registry.whereis(camera_id, :camera) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        Cairn.Registry.await_unregistered(camera_id, :camera)
    end
  end
end
