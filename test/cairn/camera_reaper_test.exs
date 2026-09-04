defmodule Cairn.CameraReaperTest do
  # DataCase: a `Cairn.CameraTracker` consults the event index in `init/1`.
  use Cairn.DataCase, async: false

  @moduletag :capture_log

  alias Cairn.CameraTracker
  alias Cairn.Config
  alias Cairn.Registry

  setup do
    camera_id = "reap_#{System.unique_integer([:positive])}"
    Cairn.SnapshotHelpers.lend_cameras(camera_id)
    %{camera_id: camera_id}
  end

  # The tracker pool sits outside every camera's media tree so a stream reset
  # cannot take an open event with it, and nothing tells a tracker its camera
  # was removed. A delete frees the id, so the survivor is one the re-created
  # camera's `ensure/1` would find — still holding the deleted camera's event
  # and still writing its checkpoint, which the re-created id makes writable
  # again.
  test "a tracker whose camera left the config is stopped", %{camera_id: camera_id} do
    tracker = start_supervised!({CameraTracker, camera_id: camera_id})
    ref = Process.monitor(tracker)

    prune(Cairn.TrackerSupervisor.Reaper, %{
      removed: [camera_id],
      known: MapSet.delete(Config.Server.known_ids(), camera_id)
    })

    assert_receive {:DOWN, ^ref, :process, ^tracker, :normal}

    # The registry unregisters on its own DOWN, which is not the one above.
    Registry.await_unregistered(camera_id, :camera_tracker)
    assert Registry.whereis(camera_id, :camera_tracker) == nil
  end

  # Every config server broadcasts on one topic, and a private server's fleet
  # is not the one this pool's cameras come from.
  test "a diff from another server is ignored", %{camera_id: camera_id} do
    tracker = start_supervised!({CameraTracker, camera_id: camera_id})
    ref = Process.monitor(tracker)

    prune(Cairn.TrackerSupervisor.Reaper, %{
      server: :private_test_server,
      removed: [camera_id],
      known: MapSet.new()
    })

    refute_receive {:DOWN, ^ref, :process, ^tracker, _reason}, 200
  end

  defp prune(owner, fields) do
    diff =
      Map.merge(
        %{
          added: [],
          removed: [],
          changed: [],
          refreshed: [],
          version: 0,
          server: Config.Server
        },
        fields
      )

    send(owner, {:config_changed, diff})
    :sys.get_state(owner)
    :ok
  end
end
