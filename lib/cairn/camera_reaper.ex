defmodule Cairn.CameraReaper do
  @moduledoc """
  Ends a camera's per-camera work when the camera leaves the config.

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

  The extractors are what this does not stop. An extractor under
  `Cairn.EventSupervisor` outlives both its
  lane owner and its camera's tree: nothing but a `{:finalize, event}` ends
  one, so a deleted camera's clip would stay open and its row `active` for as
  long as the node runs — and once the id is re-created,
  `Cairn.PresenceRecorder.sweep_stranded/1` would find the deleted
  generation's extractor and end its event as the new camera's. Killing it
  would leave the row `active` until the next boot's reconciliation, so it is
  finalized `:partial` instead: the same honest close the sweep performs, on a
  row keyed by the event rather than the camera, which is why nothing about it
  can collide with a re-created id.

  One process for all three roles, because the order among them is the point.
  Split across the pools they would have been three subscribers of one
  broadcast, and the extractor sweep could run first: a tracker with a batch
  queued ahead of its stop opens an event and starts an extractor while it is
  being stopped, and a sweep that has already run leaves that extractor
  writing a clip on an `active` row for a camera that no longer exists.

  Prunes on the application config server's diffs alone and against the
  membership that diff carries, `Cairn.EventCheckpoint`'s rule and for its
  reason.
  """

  use GenServer

  require Logger

  # A stopped lane owner's open event is abandoned rather than closed here:
  # the clip itself belongs to the extractor, which the sweep below ends
  # partial in the same pass.
  @stop_timeout 5_000

  @lane_roles [:presence_recorder, :camera_tracker]

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Cairn.Config.Server.subscribe()
    {:ok, %{}}
  end

  @impl true
  def handle_info(
        {:config_changed, %{server: Cairn.Config.Server, known: %MapSet{} = known}},
        state
      ) do
    stop_lane_owners(known)
    end_extractors(known)
    {:noreply, state}
  end

  # Another server's diff, or one without the membership this owner prunes on.
  def handle_info({:config_changed, _other}, state), do: {:noreply, state}

  # Every stop happens before the sweep below (a lane owner drains what is
  # queued ahead of its stop, so one can still open an event and start an
  # extractor while it is being stopped), but the stops among themselves run
  # concurrently: a production delete is one id, but this pass also runs on
  # every restart's diff against a surviving snapshot, where it can be many
  # at once, and one slow `terminate/2` must not serialize the rest behind
  # its `@stop_timeout`. `on_timeout: :kill_task` bounds the pass even if a
  # stop somehow outlives `GenServer.stop/3`'s own timeout; `Stream.run/1`
  # is what makes this await every task before the sweep runs.
  defp stop_lane_owners(known) do
    @lane_roles
    |> Enum.flat_map(fn role ->
      role
      |> Cairn.Registry.ids_for_role()
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.map(&{role, &1})
    end)
    |> Task.async_stream(
      fn {role, camera_id} -> stop(camera_id, role) end,
      max_concurrency: System.schedulers_online(),
      timeout: @stop_timeout + 1_000,
      on_timeout: :kill_task
    )
    |> Stream.run()
  end

  # One read of the registry is the whole set: an extractor registers in its
  # own `start_link`, inside the `start_child` its producer is blocked on, so
  # a producer that is down has none in flight — and above, every producer a
  # deleted id had is down.
  defp end_extractors(known) do
    Cairn.Registry.extractors()
    |> Enum.reject(fn {camera_id, _event_id, _pid} -> MapSet.member?(known, camera_id) end)
    |> Enum.each(&end_partial/1)
  end

  # `Cairn.PresenceRecorder.end_stranded/3`'s close, with its ordering: the
  # window is announced closed before the clip is told to land, and the cast
  # carries every box already sent ahead of it. A row that is not `active` is
  # an extractor already finalizing, and one the index cannot answer for has
  # nothing to close honestly — both are stopped instead, which leaves the row
  # to boot reconciliation rather than the process to the re-created id.
  defp end_partial({camera_id, event_id, pid}) do
    case active_row(event_id) do
      nil ->
        stop_pid(pid, camera_id, "stopping the extractor for event #{event_id}")

      row ->
        Logger.info("camera #{camera_id}: deleted, ending event #{event_id} partial")
        event = Cairn.Events.partial_event(row, DateTime.utc_now())
        Cairn.Event.broadcast(:event_ended, event)
        Cairn.EventExtractor.finalize(pid, event)
    end
  end

  # `Cairn.PresenceRecorder.active_rows/1`'s guards, for its reason: an index
  # that will not answer costs this event's honest close, not the prune.
  defp active_row(event_id) do
    case Cairn.Events.get(event_id) do
      %{status: :active} = row -> row
      _other -> nil
    end
  rescue
    e in [DBConnection.ConnectionError, DBConnection.OwnershipError, Exqlite.Error] ->
      Logger.warning("event #{event_id}: could not read the index (#{Exception.message(e)})")
      nil
  catch
    :exit, reason ->
      Logger.warning("event #{event_id}: could not read the index (#{inspect(reason)})")
      nil
  end

  defp stop(camera_id, role) do
    case Cairn.Registry.whereis(camera_id, role) do
      nil ->
        :ok

      pid ->
        stop_pid(pid, camera_id, "stopping #{role}")
    end
  end

  # Every pid here is a stale registry read: it may already be exiting, and
  # `GenServer.stop/3` on a process that dies of anything else — or that
  # outlasts the timeout — exits the caller with it.
  defp stop_pid(pid, camera_id, what) do
    Logger.info("camera #{camera_id}: deleted, #{what}")
    GenServer.stop(pid, :normal, @stop_timeout)
  catch
    :exit, _dying -> :ok
  end
end
