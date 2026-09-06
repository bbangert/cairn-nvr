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
  can collide with a re-created id. This process writes that close itself
  before it hands the finalize to the extractor — the extractor's own close
  runs the remux and may take a minute, and a row left `active` for that long
  is one the sweep could adopt.

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

  # What an extractor's finalize is given before it is killed, as opposed to
  # `@stop_timeout` above: the close runs `Cairn.ClipRemux`, which lets ffmpeg
  # have the clip for 60 s, and killing a legitimately slow remux threw away
  # the honest close it was on its way to writing. The margin covers the file
  # close and the index write either side of it. `:reaper_finalize_timeout` is
  # the seam the tests that exercise this wait shorten it through.
  @finalize_timeout 90_000

  @lane_roles [:presence_recorder, :camera_tracker]

  # Where `stop/2` looks a role's owner up to terminate it *through* its pool
  # rather than by messaging the pid directly — see `stop_pid/4` for why.
  @lane_pools %{
    presence_recorder: Cairn.PresenceSupervisor.Pool,
    camera_tracker: Cairn.TrackerSupervisor.Pool
  }

  # `stop_pass/2`'s bound on the abnormal-exit race it exists to close (see
  # there): a role that keeps handing back a fresh registrant after every
  # stop is a crash loop, not a race, and no amount of reaping fixes that —
  # the last pass raises rather than call it reaped.
  @max_stop_passes 3

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    # `name: nil` starts an unregistered instance — a test's private reaper,
    # run alongside the application's own without contending for its name.
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(_opts) do
    ref = Cairn.ConfigSubscription.subscribe()
    # Under `:one_for_one`, a delete's diff can reach the OLD pid and be lost
    # to a restart, leaving the fresh process having never pruned it. The
    # published membership is complete, so replaying this pass against it
    # closes that gap regardless of what was missed. Run here rather than from
    # a self-message: the registered name is visible to callers before `init/1`
    # returns, so any call already in the mailbox would be answered ahead of
    # anything sent to self.
    #
    # No snapshot published yet (a fresh node's boot order, or a test that
    # never lends one) means nothing is known to reconcile against.
    case Cairn.Config.Server.known_ids() do
      %MapSet{} = known -> reconcile(known)
      nil -> :ok
    end

    {:ok, %{pubsub_ref: ref}}
  end

  @impl true
  def handle_info(
        {:config_changed, %{server: Cairn.Config.Server, known: %MapSet{} = known}},
        state
      ) do
    reconcile(known)
    {:noreply, state}
  end

  # Another server's diff, or one without the membership this owner prunes on.
  def handle_info({:config_changed, _other}, state), do: {:noreply, state}

  # PubSub restarted under us: `Cairn.ConfigSubscription` re-subscribes and
  # re-monitors so this reaper keeps reaping. This is the ONLY monitor `:DOWN`
  # that reaches here — the worker monitors in `await_finalize/4` and
  # `kill_and_await/1` are created and received inline inside the
  # `Task.async_stream` task processes, so a worker's `:DOWN` never lands in
  # this mailbox. Placed after the `{:config_changed, ...}` clauses so it never
  # shadows them.
  def handle_info({:DOWN, _ref, :process, _pid, _reason} = msg, state) do
    case Cairn.ConfigSubscription.handle_down(msg, state.pubsub_ref) do
      {:ok, ref} ->
        # A delete that broadcast while the subscription was down would leave
        # its producers running; reconcile against the current fleet to reap
        # anything missed, the same pass `init/1` runs.
        Cairn.ConfigSubscription.reconcile(&reconcile/1)
        {:noreply, %{state | pubsub_ref: ref}}

      :other ->
        {:noreply, state}
    end
  end

  defp reconcile(known) do
    stop_lane_owners(known)
    end_extractors(known)
  end

  # Every stop happens before the sweep below (a lane owner drains what is
  # queued ahead of its stop, so one can still open an event and start an
  # extractor while it is being stopped), but the stops within one pass run
  # concurrently: a production delete is one id, but this also runs on every
  # restart's diff against a surviving snapshot, where it can be many at
  # once, and one slow stop must not serialize the rest. The bound is
  # `stop_pid/4`'s own — the child's `shutdown:` under
  # `DynamicSupervisor.terminate_child/2`, or `@stop_timeout` and its kill for
  # the direct fallback — so `timeout: :infinity` here leaves that per-process
  # path as the only one: an outer timeout could fire between it and its kill,
  # and killing the task there abandons a target that is merely slow rather
  # than stuck.
  #
  # One pass cannot see a race that happens inside it: a `:transient` pool
  # child that exits ABNORMALLY, for a reason of its own, between the
  # registry read below and this pass reaching it is restarted by its pool
  # first — and `DynamicSupervisor.terminate_child/2` on the now-stale pid
  # only answers `:not_found`, having stopped nothing. The replacement is
  # left registered under a deleted id, invisible to a pass that already
  # built its target list. Re-reading the registry and repeating is what
  # catches it, bounded at `@max_stop_passes` rather than looped forever
  # (see there).
  defp stop_lane_owners(known), do: stop_pass(known, @max_stop_passes)

  # Out of passes with owners still registered is the crash loop, and the one
  # outcome this must not report as reaped: a re-created id would adopt an
  # old-generation producer. Raising takes this process down instead, and the
  # restart reconciles from the published snapshot in `init/1`.
  defp stop_pass(known, 0) do
    case absent_lane_owners(known) do
      [] ->
        :ok

      remaining ->
        raise "camera reaper: #{inspect(remaining)} still registered after " <>
                "#{@max_stop_passes} stop passes"
    end
  end

  defp stop_pass(known, passes_left) do
    case absent_lane_owners(known) do
      [] ->
        :ok

      targets ->
        targets
        |> Task.async_stream(
          fn {role, camera_id} -> stop(camera_id, role) end,
          max_concurrency: System.schedulers_online(),
          timeout: :infinity
        )
        |> await_tasks()

        stop_pass(known, passes_left - 1)
    end
  end

  # `Task.async_stream/3`'s results are the only report a callback that raised
  # ever makes: discarded, a crashed stop or finalize would leave this pass
  # acknowledging a prune that did not happen. Exiting with the task's own
  # reason takes the reaper down instead, and its restart reconciles.
  defp await_tasks(stream) do
    Enum.each(stream, fn
      {:ok, _result} -> :ok
      {:exit, reason} -> exit(reason)
    end)
  end

  defp absent_lane_owners(known) do
    @lane_roles
    |> Enum.flat_map(fn role ->
      role
      |> Cairn.Registry.ids_for_role()
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.map(&{role, &1})
    end)
  end

  # One read of the registry is the whole set: an extractor registers in its
  # own `start_link`, inside the `start_child` its producer is blocked on, so
  # a producer that is down has none in flight — and above, `stop_pass/2` has
  # already brought every producer a deleted id had down (short of the crash
  # loop it gives up on past `@max_stop_passes`, which is not this sweep's
  # problem to solve).
  #
  # `end_partial/1` only casts a finalize; without waiting for the extractor
  # to actually exit, this pass would return before the file closes, the row
  # leaves `active` and the process deregisters, letting a same-id create's
  # `ensure/1` race a still-registered deleted-generation extractor. Run
  # concurrently like the stops above, for the same reason: one slow finalize
  # must not serialize the rest. The bound
  # is `await_finalize/4`'s own `@finalize_timeout` and the kill behind it, not
  # this stream — an outer timeout could kill the task between the two and
  # abandon an extractor that is merely remuxing, so `timeout: :infinity`
  # leaves that per-process path as the only one.
  defp end_extractors(known) do
    Cairn.Registry.extractors()
    |> Enum.reject(fn {camera_id, _event_id, _pid} -> MapSet.member?(known, camera_id) end)
    |> Task.async_stream(
      &end_partial/1,
      max_concurrency: System.schedulers_online(),
      timeout: :infinity
    )
    |> await_tasks()
  end

  # `Cairn.PresenceRecorder.end_stranded/3`'s close, with its ordering: the
  # window is announced closed before the clip is told to land, and the cast
  # carries every box already sent ahead of it. `drain/1` runs first so a
  # normal finalize a lane owner already cast — its own post-window firing in
  # the same breath it was told to leave — is seen before `active_row/1` is
  # read, provided that finalize completes within `drain/1`'s `@stop_timeout`
  # (5 s). It covers only sub-5s finalizes: a normal finalize runs a ~60 s
  # remux, so the drain can time out with the row still `active`, and this pass
  # then broadcasts a partial ending and casts a second finalize behind the one
  # already under way. That is accepted as harmless — the row still ends
  # correct, since the extractor's own `:finalized` close wins the last write;
  # only a redundant partial `:event_ended` goes out on the events topic.
  #
  # Still `active` after the drain, there was no such cast, and this is the
  # one thing that closes the event; gone, the extractor is finalizing on its
  # own (or the index could not answer, which is the same "nothing to close
  # honestly" either way) and there is nothing left to do but wait it out,
  # with the same kill fallback both branches share.
  defp end_partial({camera_id, event_id, pid}) do
    drain(pid)

    case active_row(event_id) do
      nil ->
        ref = Process.monitor(pid)
        await_finalize(pid, ref, camera_id, event_id)

      row ->
        Logger.info("camera #{camera_id}: deleted, ending event #{event_id} partial")
        event = Cairn.Events.partial_event(row, DateTime.utc_now())
        close_row(event, row)
        Cairn.Event.broadcast(:event_ended, event)
        # `finalize/2` only enqueues a cast; waiting out the `:DOWN` (with the
        # kill-on-timeout of `stop_pid/4` on `@finalize_timeout`) is what keeps
        # this extractor's exit, not just its finalize message, inside the pass.
        ref = Process.monitor(pid)
        Cairn.EventExtractor.finalize(pid, event)
        await_finalize(pid, ref, camera_id, event_id)
    end
  end

  # The close is written from here, ahead of the wait below, because that wait
  # is as long as a remux: an extractor killed at the end of it would leave the
  # row `active` until the next boot's reconciliation, and for the whole minute
  # before that `Cairn.PresenceRecorder.sweep_stranded/1` — which reads exactly
  # the `active` rows — could adopt it into a re-created camera. Closed first,
  # there is nothing for the sweep to find whatever the extractor does next.
  #
  # The extractor still finalizes afterwards and writes the same row again:
  # `Cairn.Events.close/3` re-reads by id and updates whatever status it finds,
  # so the second close is a rewrite rather than an error, and it is the one
  # that lands the post-remux byte count over the row bytes used here.
  defp close_row(event, row) do
    case Cairn.Events.finalize_partial(event, row.bytes || 0) do
      {:ok, _row} -> :ok
      {:error, reason} -> log_close_failure(event.id, inspect(reason))
    end
  rescue
    e in [DBConnection.ConnectionError, DBConnection.OwnershipError, Exqlite.Error] ->
      log_close_failure(event.id, Exception.message(e))
  catch
    :exit, reason ->
      log_close_failure(event.id, inspect(reason))
  end

  # `active_row/1`'s rule at the other end of the same write: an index that
  # will not answer costs this event's honest close, not the prune — and the
  # extractor's own finalize, still cast below, gets the next attempt at it.
  defp log_close_failure(event_id, reason) do
    Logger.warning("event #{event_id}: could not close the row partial (#{reason})")
  end

  # Flushes whatever is already queued for this extractor before the row
  # below is read — chiefly a normal finalize cast a lane owner enqueued
  # ahead of its own stop. `:sys.get_state/2` processes the mailbox up to and
  # including itself and costs nothing extra when nothing is queued. Bounded at
  # `@stop_timeout` and not the longer `@finalize_timeout`, so an extractor too
  # slow to answer is treated as already gone rather than costing this pass a
  # remux's worth of waiting twice over.
  defp drain(pid) do
    :sys.get_state(pid, @stop_timeout)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp await_finalize(pid, ref, camera_id, event_id) do
    timeout = finalize_timeout()

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Logger.warning(
          "camera #{camera_id}: finalizing event #{event_id} did not finish in " <>
            "#{timeout}ms; killing it"
        )

        # `kill_and_await/1` monitors again itself; drop this one first so its
        # `:DOWN` does not sit unread in the mailbox once the kill lands.
        Process.demonitor(ref, [:flush])
        kill_and_await(pid)
    end
  end

  defp finalize_timeout,
    do: Application.get_env(:cairn, :reaper_finalize_timeout, @finalize_timeout)

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
        stop_pid(pid, camera_id, role, "stopping #{role}")
    end
  end

  # Every pid here is a stale registry read: it may already be exiting, may
  # already have been replaced by its pool's own restart (the abnormal-exit
  # race `stop_pass/2` repeats passes to catch), or — a test harness that
  # starts one directly rather than under its pool — may never have been that
  # pool's child at all.
  #
  # `DynamicSupervisor.terminate_child/2` is tried first, through the pool
  # that owns this role: an explicit terminate is never mistaken for a crash
  # to restart, which is exactly the property `GenServer.stop/3` could not
  # give — a target whose shutdown dies of anything else exits the *caller*
  # with it, leaving its pool to read the crash as its own and restart a
  # `:transient` child this pass meant to end for good. `:not_found` covers
  # every case above where the pool has nothing of this pid to terminate, and
  # falls back to a direct stop bounded the same way.
  defp stop_pid(pid, camera_id, role, what) do
    Logger.info("camera #{camera_id}: deleted, #{what}")

    case DynamicSupervisor.terminate_child(Map.fetch!(@lane_pools, role), pid) do
      :ok -> :ok
      {:error, :not_found} -> stop_directly(pid, camera_id, what)
    end
  end

  defp stop_directly(pid, camera_id, what) do
    GenServer.stop(pid, :normal, @stop_timeout)
  catch
    # A timeout leaves the target ALIVE — the process `GenServer.stop/3` kills
    # on its way out is the helper that was waiting on it — and Elixir reports
    # it as `{:timeout, {GenServer, :stop, _}}`. Taking that for a stop would
    # run the extractor sweep against a live producer, the one thing the stops
    # exist to prevent, so the slow one is taken away instead. `@stop_timeout`
    # bounds the wait regardless of why the terminate is slow — a terminate
    # blocked on a lock, a long drain, or a producer simply mid-work — and the
    # kill is what enforces that bound. A target that died *of* a timeout of
    # its own matches too, and a kill it does not need is harmless.
    :exit, {:timeout, _stop} ->
      Logger.warning(
        "camera #{camera_id}: #{what} did not finish in #{@stop_timeout}ms; killing it"
      )

      kill_and_await(pid)

    :exit, _dying ->
      :ok
  end

  defp kill_and_await(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end
end
