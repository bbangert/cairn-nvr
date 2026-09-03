defmodule Cairn.CameraControlTest do
  # Uses the globally-supervised Cairn.CameraControl; unique camera ids per
  # test. NOT async: the prune test empties the shared table down to its own
  # rows, deleting control state concurrent suites rely on mid-test — the
  # presence suites' recording_enabled: false isolation in particular.
  use ExUnit.Case, async: false

  alias Cairn.CameraControl

  test "defaults to on/on/no-override for an unknown camera" do
    id = "cc_#{System.unique_integer([:positive])}"

    assert CameraControl.get(id) == %{
             detection_enabled: true,
             recording_enabled: true,
             min_score: nil
           }
  end

  test "set merges partial attrs and returns the new control" do
    id = "cc_#{System.unique_integer([:positive])}"

    assert %{detection_enabled: false, recording_enabled: true, min_score: nil} =
             CameraControl.set(id, %{detection_enabled: false})

    assert %{detection_enabled: false, min_score: 0.8} = CameraControl.set(id, %{min_score: 0.8})
  end

  test "set broadcasts on the control topic" do
    id = "cc_#{System.unique_integer([:positive])}"
    CameraControl.subscribe()

    CameraControl.set(id, %{recording_enabled: false})

    assert_receive {:camera_control, ^id, %{recording_enabled: false}}
  end

  test "prune removes cameras no longer configured" do
    keep = "cc_keep_#{System.unique_integer([:positive])}"
    drop = "cc_drop_#{System.unique_integer([:positive])}"
    CameraControl.set(keep, %{detection_enabled: false})
    CameraControl.set(drop, %{detection_enabled: false})

    # prune is a call, so its deletes are visible to these ETS reads. Every
    # other id stays known: the shared server's rows belong to other tests,
    # and a prune now tombstones what it drops.
    CameraControl.prune(Map.keys(CameraControl.all()) -- [drop])

    assert CameraControl.get(keep).detection_enabled == false

    assert CameraControl.get(drop) == %{
             detection_enabled: true,
             recording_enabled: true,
             min_score: nil
           }
  end

  test "ignores unknown attr keys" do
    id = "cc_#{System.unique_integer([:positive])}"
    control = CameraControl.set(id, %{bogus: 1, detection_enabled: false})
    refute Map.has_key?(control, :bogus)
    assert control.detection_enabled == false
  end

  test "a pruned camera's writes are refused until revive" do
    id = "cc_gone_#{System.unique_integer([:positive])}"
    CameraControl.set(id, %{detection_enabled: false})

    # Keep every other suite's rows: a bare `prune([])` would tombstone the
    # whole shared table, and a tombstone outlives this test.
    CameraControl.prune(CameraControl.all() |> Map.keys() |> List.delete(id))

    assert CameraControl.set(id, %{detection_enabled: false}) == {:error, :removed}
    assert CameraControl.get(id).detection_enabled == true

    assert CameraControl.revive(id) == :ok
    assert %{detection_enabled: false} = CameraControl.set(id, %{detection_enabled: false})
  end

  test "revive is a no-op for an id that was never pruned" do
    id = "cc_#{System.unique_integer([:positive])}"
    assert CameraControl.revive(id) == :ok
    assert %{min_score: 0.4} = CameraControl.set(id, %{min_score: 0.4})
  end

  test "tombstone/1 refuses writes for an id that never held a row" do
    id = "tomb_#{System.unique_integer([:positive])}"
    assert :ok = CameraControl.tombstone(id)
    assert {:error, :removed} = CameraControl.set(id, %{detect: false})
    assert :ok = CameraControl.revive(id)
    assert %{} = CameraControl.set(id, %{detect: false})
  end

  # The tombstone set used to live only in GenServer state, which a restart
  # resets to `MapSet.new()` — a paused (tombstoned) id would answer as live
  # again the moment the supervisor brought a fresh CameraControl up. It now
  # comes back out of `:persistent_term`, which the crash does not touch.
  test "a tombstone survives the supervisor restarting CameraControl" do
    id = "cc_restart_#{System.unique_integer([:positive])}"
    assert :ok = CameraControl.tombstone(id)

    try do
      pid = Process.whereis(CameraControl)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      restarted = wait_for_new_pid(pid)
      # A synchronous call as the barrier: the name is registered before
      # `init/1` runs, so `Process.whereis/1` alone would not prove the
      # persistent-term reload had happened yet.
      :sys.get_state(restarted)

      assert CameraControl.set(id, %{detection_enabled: false}) == {:error, :removed}
    after
      CameraControl.revive(id)
    end
  end

  # No sleep: the restart is a supervisor's business, not a timed one, so
  # this spins on the registration itself until the new pid shows up.
  defp wait_for_new_pid(old_pid) do
    case Process.whereis(CameraControl) do
      nil -> wait_for_new_pid(old_pid)
      ^old_pid -> wait_for_new_pid(old_pid)
      pid -> pid
    end
  end
end
