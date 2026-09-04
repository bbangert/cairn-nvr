defmodule Cairn.CameraReaper do
  @moduledoc """
  Stops the per-camera process in one pool when the camera leaves the config.

  The event lanes live outside their camera's media tree — a
  `Cairn.PresenceRecorder` under `Cairn.PresenceSupervisor.Pool`, a
  `Cairn.CameraTracker` under `Cairn.TrackerSupervisor.Pool` — precisely so a
  camera stop does not take the open event's clip with it: the recorder
  latches its `retire/1` until the post window closes and the tracker is not
  told about the stop at all. Both survivals are written for a restart and for
  a disable, where the id stays in the config.

  A **delete** is the stop that must not be survived. The id is free again, so
  a re-created camera's `ensure/1` would adopt the process the deleted camera
  left — and its checkpoint, its open event and its extractor would land under
  the new camera, which the config's contract says starts from defaults. The
  checkpoint owners drop a write for an unknown camera, but a re-created id is
  known again, so the drop cannot be what protects it; the writer has to be
  gone. Stopping it also ends the only path by which
  `Cairn.PresenceRecorder.ensure/1` could hand a caller anything but a fresh
  process for a re-created id.

  One instance per pool, told its `Cairn.Registry` role. Prunes on the
  application config server's diffs alone and against the membership that diff
  carries, `Cairn.EventCheckpoint`'s rule and for its reason.
  """

  use GenServer

  require Logger

  # An open event's clip is abandoned rather than finalized: its camera is
  # gone, so there is nothing the recording is of any more, and the alternative
  # is a finalize racing the re-create it is meant to be invisible to.
  @stop_timeout 5_000

  @doc "`:role` is the `t:Cairn.Registry.role/0` this instance reaps."
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Cairn.Config.Server.subscribe()
    {:ok, %{role: Keyword.fetch!(opts, :role)}}
  end

  @impl true
  def handle_info(
        {:config_changed, %{server: Cairn.Config.Server, known: %MapSet{} = known}},
        state
      ) do
    state.role
    |> Cairn.Registry.ids_for_role()
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.each(&stop(&1, state.role))

    {:noreply, state}
  end

  # Another server's diff, or one without the membership this owner prunes on.
  def handle_info({:config_changed, _other}, state), do: {:noreply, state}

  # The registry is a stale-read site: the pid may already be exiting, and
  # `GenServer.stop/3` on a process that dies of anything else — or that
  # outlasts the timeout — exits the caller with it.
  defp stop(camera_id, role) do
    case Cairn.Registry.whereis(camera_id, role) do
      nil ->
        :ok

      pid ->
        Logger.info("camera #{camera_id}: deleted, stopping #{role}")
        GenServer.stop(pid, :normal, @stop_timeout)
    end
  catch
    :exit, _dying -> :ok
  end
end
