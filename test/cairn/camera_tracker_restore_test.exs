defmodule Cairn.CameraTrackerRestoreTest do
  # Deliberately NOT `Cairn.DataCase`: with no sandbox connection checked out,
  # every Repo call made from this module raises `DBConnection.OwnershipError`.
  # That is the suite's faithful stand-in for "the database is not answering",
  # which is the condition checkpoint restore has to survive — it runs inside
  # `init/1`, and a camera whose stream is otherwise fine must not lose its
  # tracker to an index that will not answer.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Cairn.{CameraTracker, DataCase, Event, EventCheckpoint, Events}

  setup do
    DataCase.reset_checkpoints()
    Event.subscribe()
    :ok
  end

  test "restore survives an unreachable event index and still ends the orphan" do
    await_unreachable_index()

    camera_id = "trk_#{System.unique_integer([:positive])}"

    event = %Event{
      id: Ecto.UUID.generate(),
      camera_id: camera_id,
      started_at: DateTime.utc_now()
    }

    EventCheckpoint.put!(camera_id, event)
    eid = event.id

    log =
      capture_log(fn ->
        tracker =
          start_supervised!({CameraTracker, camera_id: camera_id, name: nil},
            id: :tracker_restore_no_index
          )

        assert Process.alive?(tracker)
        assert_receive {:event_ended, %Event{id: ^eid, status: :partial}}
        assert EventCheckpoint.all() |> Enum.filter(&(elem(&1, 0) == camera_id)) == []
      end)

    assert log =~ "could not consult the event index"
  end

  # The case the sweep exists for, and the only one it can ever find work in:
  # rows that outlived every tracker that wrote them. A tracker crash-looping
  # past `Cairn.TrackerSupervisor.Pool`'s restart intensity takes the pool and
  # all its trackers down while the checkpoint table, owned elsewhere, stays —
  # and the subtree's `:rest_for_one` is what re-runs the sweep over it. Killing
  # the pool outright is that cascade with the crash loop skipped.
  #
  # Nothing here ever addresses the camera, which is the point: a tracker under
  # that registered name can only have come from the sweep, so the assertion
  # fails exactly when the restore has gone back to waiting on the camera's next
  # observation.
  test "a pool restart re-runs the sweep, restoring a camera nothing has observed" do
    await_unreachable_index()

    camera_id = "trk_#{System.unique_integer([:positive])}"

    event = %Event{
      id: Ecto.UUID.generate(),
      camera_id: camera_id,
      started_at: DateTime.utc_now()
    }

    EventCheckpoint.put!(camera_id, event)
    eid = event.id
    on_exit(fn -> terminate_tracker(camera_id) end)

    capture_log(fn ->
      # Kills every tracker under the app's pool, not just this camera's. Safe
      # only while this file and every suite that parks real trackers under the
      # pool (camera_tracker_test.exs's isolation tests) are `async: false` —
      # an async suite's tracker dying mid-test would fail it spuriously.
      Process.exit(Process.whereis(Cairn.TrackerSupervisor.Pool), :kill)

      assert tracker = await_registered(camera_id)
      assert Process.alive?(tracker)

      # ...holding what the row said: the orphan is ended partial and the row
      # it was restored from is gone
      assert_receive {:event_ended, %Event{id: ^eid, status: :partial}}
      assert EventCheckpoint.get(camera_id) == nil
    end)
  end

  # Two supervisor restarts deep (the pool, then the task), so polled rather
  # than slept on.
  defp await_registered(camera_id, attempts \\ 200) do
    case Cairn.Registry.whereis(camera_id, :camera_tracker) do
      pid when is_pid(pid) ->
        pid

      nil when attempts > 0 ->
        Process.sleep(10)
        await_registered(camera_id, attempts - 1)

      nil ->
        flunk("no tracker was registered for #{camera_id}: the restore sweep never re-ran")
    end
  end

  # The pool outlives the test, so a tracker left running would answer a later
  # `ensure/1` for the same id.
  defp terminate_tracker(camera_id) do
    case Cairn.Registry.whereis(camera_id, :camera_tracker) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Cairn.TrackerSupervisor.Pool, pid)
    end
  end

  # This module inherits the tail of the previous one's sandbox teardown: while
  # a shared owner is exiting, a Repo call *exits* with "owner exited" rather
  # than raising `DBConnection.OwnershipError`. Both are "the index is not
  # answering", but only the second is stable — once the ownership manager has
  # reaped the owner every call raises, and no owner can appear afterwards
  # because this module never checks one out. Waiting for that state, and
  # failing loudly if the index turns out to be reachable, is what stops the
  # test from passing vacuously against a working index.
  defp await_unreachable_index(attempts \\ 100) do
    case probe_index() do
      {:raised, %DBConnection.OwnershipError{}} ->
        :ok

      _other when attempts > 0 ->
        Process.sleep(10)
        await_unreachable_index(attempts - 1)

      other ->
        flunk("the event index is still reachable from this test: #{inspect(other)}")
    end
  end

  defp probe_index do
    {:ok, Events.get(Ecto.UUID.generate())}
  rescue
    e -> {:raised, e}
  catch
    :exit, reason -> {:exited, reason}
  end
end
