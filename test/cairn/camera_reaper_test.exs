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

  # Registered under the tracker role and starting its extractor from
  # `terminate/2`: that is the only instant a real tracker's own race is
  # reachable on demand. A `{:tracked, ...}` cast queued ahead of the reaper's
  # stop is drained before it, so the tracker can open an event — and register
  # its extractor — while the reaper is inside `GenServer.stop/3`. Driving a
  # `Cairn.CameraTracker` to that point needs a whole inference batch and
  # still leaves the instant to chance.
  defmodule TrackerStub do
    @moduledoc false
    # `:temporary`: the reaper's stop is a normal exit, and a restarted stub
    # would start the same event's extractor a second time at test teardown.
    use GenServer, restart: :temporary

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)
      {:ok, _} = Cairn.Registry.register(Keyword.fetch!(opts, :camera_id), :camera_tracker)
      {:ok, Map.new(opts)}
    end

    @impl true
    def terminate(_reason, state) do
      {:ok, pid} =
        DynamicSupervisor.start_child(
          Cairn.EventSupervisor,
          {Cairn.EventExtractor, state.extractor_opts}
        )

      # The `active` row lands in the extractor's `handle_continue(:open,
      # ...)`, which a real tracker's start would have waited out too: it
      # holds the pid the supervisor answered with, and the reaper's sweep is
      # the next thing to run either way.
      :sys.get_state(pid)
      send(state.test, {:extractor_started, pid})
      :ok
    end
  end

  # A lane owner whose `terminate/2` never returns: `GenServer.stop/3` times
  # out on it with the process still alive and still able to produce. The real
  # shape is a terminate blocked on the config server, which is itself blocked
  # on this very pass (`Cairn.Config.Server`'s barrier).
  defmodule HangingTrackerStub do
    @moduledoc false
    use GenServer, restart: :temporary

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)
      {:ok, _} = Cairn.Registry.register(Keyword.fetch!(opts, :camera_id), :camera_tracker)
      {:ok, Map.new(opts)}
    end

    @impl true
    def terminate(_reason, _state), do: Process.sleep(:infinity)
  end

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
      start_supervised!({TrackerStub, camera_id: camera_id, extractor_opts: opts, test: self()})

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
    stub = start_supervised!({HangingTrackerStub, camera_id: camera_id})
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
