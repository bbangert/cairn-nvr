defmodule Cairn.CameraReaperTest do
  # DataCase: a `Cairn.CameraTracker` consults the event index in `init/1`.
  use Cairn.DataCase, async: false

  @moduletag :capture_log

  alias Cairn.CameraReaper
  alias Cairn.CameraTracker
  alias Cairn.Config
  alias Cairn.Event
  alias Cairn.EventExtractor
  alias Cairn.Events
  alias Cairn.Registry
  alias Cairn.RingBuffer

  # `Cairn.TrackerStub`, `Cairn.HangingTrackerStub` and `Cairn.RaisingTrackerStub`
  # live in test/support/tracker_stubs.ex — see there for what each stands in for.

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

    prune(%{
      removed: [camera_id],
      known: Cairn.SnapshotHelpers.known_ids_excluding(camera_id)
    })

    assert_receive {:DOWN, ^ref, :process, ^tracker, :normal}

    # The registry unregisters on its own DOWN, which is not the one above.
    Registry.await_unregistered(camera_id, :camera_tracker)
    assert Registry.whereis(camera_id, :camera_tracker) == nil
  end

  # Every config server broadcasts on one topic, and a private server's fleet
  # is not the one this node's cameras come from.
  test "a diff from another server is ignored", %{camera_id: camera_id} do
    tracker = start_supervised!({CameraTracker, camera_id: camera_id})
    ref = Process.monitor(tracker)

    prune(%{
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

    prune(%{
      removed: [camera_id],
      known: Cairn.SnapshotHelpers.known_ids_excluding(camera_id)
    })

    assert_receive {:DOWN, ^ref, :process, ^extractor, :normal}, 5_000
    assert Events.get(event_id).status == :partial
    assert Registry.whereis(camera_id, {:extractor, event_id}) == nil
  end

  # The reason the three roles are one process: the stops come first and are
  # synchronous, so an extractor a lane owner starts on its way down is
  # already registered when the sweep reads the registry. Three subscribers of
  # one broadcast could sweep before the stop and leave this extractor writing
  # a clip on an `active` row for a camera that no longer exists.
  test "an extractor started while its tracker is being stopped is ended too", %{
    camera_id: camera_id
  } do
    {opts, event_id} = extractor_opts(camera_id)

    stub =
      start_supervised!(
        {Cairn.TrackerStub, camera_id: camera_id, extractor_opts: opts, test: self()}
      )

    stub_ref = Process.monitor(stub)

    prune(%{
      removed: [camera_id],
      known: Cairn.SnapshotHelpers.known_ids_excluding(camera_id)
    })

    assert_receive {:DOWN, ^stub_ref, :process, ^stub, :normal}
    assert_received {:extractor_started, extractor}

    ref = Process.monitor(extractor)
    assert_receive {:DOWN, ^ref, :process, ^extractor, _reason}, 5_000
    assert Events.get(event_id).status == :partial
    assert Registry.whereis(camera_id, {:extractor, event_id}) == nil
  end

  # A disable keeps the id in the config, and an event mid-recording when the
  # camera goes dark is still an event: only a delete ends it.
  test "an extractor whose camera is still known is left writing", %{camera_id: camera_id} do
    {extractor, event_id} = start_extractor(camera_id)
    ref = Process.monitor(extractor)

    prune(%{
      removed: ["some_other_camera"],
      known: Config.Server.known_ids()
    })

    refute_receive {:DOWN, ^ref, :process, ^extractor, _reason}, 200
    assert Events.get(event_id).status == :active
  end

  # A stop taken for done while the target still runs is the failure this
  # guards: the sweep would then read the registry while a live producer can
  # still start an extractor into it. Takes `@stop_timeout` to run — the wait
  # is the thing under test.
  test "a lane owner that outlasts the stop timeout is killed, and the sweep still runs", %{
    camera_id: camera_id
  } do
    {extractor, event_id} = start_extractor(camera_id)
    stub = start_supervised!({Cairn.HangingTrackerStub, camera_id: camera_id})
    stub_ref = Process.monitor(stub)
    extractor_ref = Process.monitor(extractor)

    prune(%{
      removed: [camera_id],
      known: Cairn.SnapshotHelpers.known_ids_excluding(camera_id)
    })

    assert_receive {:DOWN, ^stub_ref, :process, ^stub, :killed}, 10_000
    assert_receive {:DOWN, ^extractor_ref, :process, ^extractor, :normal}, 5_000
    assert Events.get(event_id).status == :partial
  end

  # `DynamicSupervisor.terminate_child/2` treats an explicit terminate as
  # ended regardless of how badly `terminate/2` behaves, unlike
  # `GenServer.stop/3`: a target that dies of anything else while that call
  # is in flight exits the *caller* with it, and the pool reads the crash as
  # its own and restarts the `:transient` child this pass meant to end for
  # good. Started under the real pool (not `start_supervised!`), because that
  # restart is exactly what is under test here.
  test "a lane owner whose terminate/2 raises is not restarted by its pool", %{
    camera_id: camera_id
  } do
    {:ok, stub} =
      DynamicSupervisor.start_child(
        Cairn.TrackerSupervisor.Pool,
        {Cairn.RaisingTrackerStub, camera_id: camera_id}
      )

    on_exit(fn ->
      case Registry.whereis(camera_id, :camera_tracker) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Cairn.TrackerSupervisor.Pool, pid)
      end
    end)

    ref = Process.monitor(stub)

    prune(%{
      removed: [camera_id],
      known: Cairn.SnapshotHelpers.known_ids_excluding(camera_id)
    })

    assert_receive {:DOWN, ^ref, :process, ^stub, _reason}

    # Not merely "eventually unregistered": a restart would leave a FRESH
    # registrant behind under the same id, which this also rules out.
    Registry.await_unregistered(camera_id, :camera_tracker)
    refute Registry.whereis(camera_id, :camera_tracker)
  end

  # A lane owner may cast its extractor's normal finalize just ahead of its
  # own stop — a post window firing in the same breath the owner is told to
  # leave — and this pass must see that finalize land before it decides
  # whether the event is still open, or it emits a partial ending that
  # contradicts the finalize already under way.
  test "an extractor already told to finalize is not ended partial", %{camera_id: camera_id} do
    {extractor, event_id} = start_extractor(camera_id)
    ref = Process.monitor(extractor)
    Event.subscribe()

    # `EventExtractor.finalize/2` takes the runtime `%Cairn.Event{}` the
    # tracker/recorder carries, not the `Cairn.Events.Event` row `Events.get/1`
    # answers with — `Events.partial_event/2` is the same conversion
    # `end_partial/1` itself uses, with the status a normal close carries.
    event = %{Events.partial_event(Events.get(event_id), DateTime.utc_now()) | status: :finalized}
    EventExtractor.finalize(extractor, event)

    prune(%{
      removed: [camera_id],
      known: Cairn.SnapshotHelpers.known_ids_excluding(camera_id)
    })

    assert_receive {:DOWN, ^ref, :process, ^extractor, :normal}, 5_000
    # This test's extractor never saw a keyframe, so its own close still
    # lands `:partial` on the row (`Cairn.EventExtractor.finish/2`'s no-media
    # rule) — a fact about this fixture, not about the reaper. What proves the
    # fix is that the reaper never spoke: no second, contradictory
    # `:event_ended` of its own.
    refute_received {:event_ended, %Event{id: ^event_id, status: :partial}}
    assert Registry.whereis(camera_id, {:extractor, event_id}) == nil
  end

  defp start_extractor(camera_id) do
    {opts, event_id} = extractor_opts(camera_id)
    pid = start_supervised!({EventExtractor, opts})

    # `:sys.get_state/1` returns only once `handle_continue(:open, ...)` has,
    # and that is where the `active` row is written: a prune that arrives
    # first finds no row to close and stops the process instead, a real path
    # but not the one under test.
    :sys.get_state(pid)
    assert Events.get(event_id).status == :active
    {pid, event_id}
  end

  defp extractor_opts(camera_id) do
    dir = Path.join(System.tmp_dir!(), "cairn_reap_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!({RingBuffer, camera_id: camera_id, pre_window_seconds: 5})

    event = %Event{
      id: Ecto.UUID.generate(),
      camera_id: camera_id,
      started_at: DateTime.utc_now()
    }

    opts = [
      camera: %Config.Camera{id: camera_id, rtsp_url: "rtsp://h/1"},
      event: event,
      config: %Config{data_dir: dir, remux_clips: false},
      snapshot_fun: fn _row, _config -> :ok end
    ]

    {opts, event.id}
  end

  defp prune(fields) do
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

    # `:sys.get_state/1` is what orders the prune, which runs in the reaper's
    # process, against the assertions below it. Its own delete is one id, but
    # in the full suite it must also outlast every other suite's fixture
    # lane owners, so the sync gets a generous timeout.
    send(CameraReaper, {:config_changed, diff})
    :sys.get_state(CameraReaper, 15_000)
    :ok
  end
end
