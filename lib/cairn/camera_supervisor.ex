defmodule Cairn.CameraSupervisor do
  @moduledoc """
  DynamicSupervisor over per-camera supervision trees (`Cairn.Camera`).

  Camera UDP port allocation is positional (see `Cairn.UDPPorts`), so
  start/stop take the camera's index in the config list. `sync/1` reconciles
  running cameras against a config; `apply_diff/2` applies a reload diff.
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
    running = MapSet.new(Cairn.Registry.ids_for_role(:camera))
    wanted = MapSet.new(config.cameras, & &1.id)

    Enum.each(MapSet.difference(running, wanted), &stop_camera/1)

    config.cameras
    |> Enum.with_index()
    |> Enum.each(fn {cam, index} ->
      unless MapSet.member?(running, cam.id), do: start_camera(config, cam, index)
    end)
  end

  @doc "Applies a `Cairn.Config.Server` reload diff against `new_config`."
  @spec apply_diff(Config.Server.diff(), Config.t()) :: :ok
  def apply_diff(diff, %Config{} = new_config) do
    Enum.each(diff.removed ++ diff.changed, &stop_camera/1)
    sync(new_config)
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
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end
end
