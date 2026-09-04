defmodule Cairn.CameraReaperTest do
  # DataCase: a `Cairn.CameraTracker` consults the event index in `init/1`.
  use Cairn.DataCase, async: false

  @moduletag :capture_log

  alias Cairn.CameraTracker
  alias Cairn.Config
  alias Cairn.Event
  alias Cairn.EventExtractor
  alias Cairn.Events
  alias Cairn.Registry
  alias Cairn.RingBuffer

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

  # An extractor is nobody else's to end: it lives under
  # `Cairn.EventSupervisor`, outlives both its lane owner and its camera's
  # tree, and exits only on a finalize. Left behind by a delete it holds the
  # clip open and the row `active` for as long as the node runs — and once the
  # id is re-created, `Cairn.PresenceRecorder`'s stranded sweep would close the
  # deleted generation's event as the new camera's.
  test "an extractor whose camera left the config is ended partial", %{camera_id: camera_id} do
    {extractor, event_id} = start_extractor(camera_id)
    ref = Process.monitor(extractor)

    prune(Cairn.EventSupervisor.Reaper, %{
      removed: [camera_id],
      known: MapSet.delete(Config.Server.known_ids(), camera_id)
    })

    assert_receive {:DOWN, ^ref, :process, ^extractor, :normal}, 5_000
    assert Events.get(event_id).status == :partial
    assert Registry.whereis(camera_id, {:extractor, event_id}) == nil
  end

  # A disable keeps the id in the config, and an event mid-recording when the
  # camera goes dark is still an event: only a delete ends it.
  test "an extractor whose camera is still known is left writing", %{camera_id: camera_id} do
    {extractor, event_id} = start_extractor(camera_id)
    ref = Process.monitor(extractor)

    prune(Cairn.EventSupervisor.Reaper, %{
      removed: ["some_other_camera"],
      known: Config.Server.known_ids()
    })

    refute_receive {:DOWN, ^ref, :process, ^extractor, _reason}, 200
    assert Events.get(event_id).status == :active
  end

  defp start_extractor(camera_id) do
    dir = Path.join(System.tmp_dir!(), "cairn_reap_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!({RingBuffer, camera_id: camera_id, pre_window_seconds: 5})

    event = %Event{
      id: Ecto.UUID.generate(),
      camera_id: camera_id,
      started_at: DateTime.utc_now()
    }

    pid =
      start_supervised!(
        {EventExtractor,
         camera: %Config.Camera{id: camera_id, rtsp_url: "rtsp://h/1"},
         event: event,
         config: %Config{data_dir: dir, remux_clips: false},
         snapshot_fun: fn _row, _config -> :ok end}
      )

    # The `active` row is written in the extractor's `handle_continue(:open,
    # ...)`, after `start_link` has returned: a prune sent before it lands
    # finds no row to close and stops the process instead, which is a real
    # path but not the one under test.
    wait_row(event.id)
    {pid, event.id}
  end

  defp wait_row(id, attempts \\ 100) do
    case Events.get(id) do
      nil when attempts > 0 ->
        Process.sleep(10)
        wait_row(id, attempts - 1)

      nil ->
        flunk("no index row for event #{id} within 1s")

      row ->
        row
    end
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
