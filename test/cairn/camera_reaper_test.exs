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

  # The stubs this file drives — `Cairn.TrackerStub`, `Cairn.HangingTrackerStub`,
  # `Cairn.RaisingTrackerStub`, `Cairn.RespawningTrackerStub` and
  # `Cairn.SlowExtractorStub` — live in test/support/tracker_stubs.ex; see there
  # for what each stands in for.

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

  # The common tier-2 case: a camera runs both a presence recorder and a
  # camera tracker, and a single delete/reconcile must end both lane owners,
  # not one of them.
  test "a camera with both lane owners has both ended in one pass", %{camera_id: camera_id} do
    tracker = start_supervised!({CameraTracker, camera_id: camera_id})
    recorder = start_lane_owner(camera_id, :presence_recorder)
    tracker_ref = Process.monitor(tracker)
    recorder_ref = Process.monitor(recorder)

    prune(%{
      removed: [camera_id],
      known: Cairn.SnapshotHelpers.known_ids_excluding(camera_id)
    })

    assert_receive {:DOWN, ^tracker_ref, :process, ^tracker, :normal}
    assert_receive {:DOWN, ^recorder_ref, :process, ^recorder, :normal}

    Registry.await_unregistered(camera_id, :camera_tracker)
    Registry.await_unregistered(camera_id, :presence_recorder)
    assert Registry.whereis(camera_id, :camera_tracker) == nil
    assert Registry.whereis(camera_id, :presence_recorder) == nil
  end

  # A delete for an id with no registered lane owner and no active row has
  # nothing to reap: the pass must be a silent no-op and leave other cameras'
  # producers untouched.
  test "reaping a camera with nothing registered is a no-op", %{camera_id: camera_id} do
    other_id = "reap_#{System.unique_integer([:positive])}"
    Cairn.SnapshotHelpers.lend_cameras(other_id)
    survivor = start_supervised!({CameraTracker, camera_id: other_id})
    survivor_ref = Process.monitor(survivor)

    prune(%{
      removed: [camera_id],
      known: Cairn.SnapshotHelpers.known_ids_excluding(camera_id)
    })

    refute_receive {:DOWN, ^survivor_ref, :process, ^survivor, _reason}, 200
    assert Registry.whereis(other_id, :camera_tracker) == survivor
  end

  # A PubSub restart drops the reaper's subscription; the monitor+resubscribe
  # in `Cairn.ConfigSubscription` gives it a fresh subscription and a fresh
  # monitor ref. The real `Cairn.PubSub` is never killed here — a synthetic
  # `:DOWN` for the stored ref drives the same path.
  test "a PubSub :DOWN re-subscribes and re-monitors" do
    reaper = private_reaper()
    %{pubsub_ref: ref} = :sys.get_state(reaper)

    send(reaper, {:DOWN, ref, :process, self(), :killed})

    %{pubsub_ref: new_ref} = :sys.get_state(reaper)
    assert is_reference(new_ref)
    refute new_ref == ref
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

  # Under `:one_for_one`, a delete's diff can land on the OLD reaper pid and
  # be lost to a restart, leaving the fresh process having pruned nothing. The
  # stub here stands for a lane owner that survived exactly that: never named
  # in the published snapshot, still registered when a private reaper starts.
  # The pass runs inside `init/1`, so it is done before `start_link` returns:
  # the registered name is visible to callers first, so a call enqueued
  # against a self-sent `:reconcile` would have been answered ahead of it.
  test "a fresh reaper reconciles against the published snapshot on init" do
    camera_id = "reap_orphan_#{System.unique_integer([:positive])}"

    stub =
      start_supervised!(%{
        id: :orphan_tracker_stub,
        restart: :temporary,
        start:
          {Agent, :start_link,
           [fn -> {:ok, _} = Registry.register(camera_id, :camera_tracker) end]}
      })

    start_supervised!({CameraReaper, name: nil})

    refute Process.alive?(stub)
    Registry.await_unregistered(camera_id, :camera_tracker)
    assert Registry.whereis(camera_id, :camera_tracker) == nil
  end

  # An extractor's own finalize runs `Cairn.ClipRemux`, which gives ffmpeg 60 s
  # over the clip: a delete that lands mid-remux is slow, not wedged, and the
  # 5 s stop timeout killed it before it could write its close.
  test "an extractor whose finalize outlasts the stop timeout is waited out", %{
    camera_id: camera_id
  } do
    event_id = active_row!(camera_id)

    # Over the finalize below and well under the 90 s a remux really gets: the
    # test measures the wait, not the bound. The suite's own 5 s (config/test.exs)
    # would kill this extractor exactly as the old `@stop_timeout` did.
    previous = Application.get_env(:cairn, :reaper_finalize_timeout)
    Application.put_env(:cairn, :reaper_finalize_timeout, 20_000)
    on_exit(fn -> Application.put_env(:cairn, :reaper_finalize_timeout, previous) end)

    stub =
      start_supervised!(
        {Cairn.SlowExtractorStub, camera_id: camera_id, event_id: event_id, finalize_ms: 6_000}
      )

    ref = Process.monitor(stub)

    prune(%{
      removed: [camera_id],
      known: Cairn.SnapshotHelpers.known_ids_excluding(camera_id)
    })

    # `:normal`, not `:killed`: the finalize ran to its own end.
    assert_receive {:DOWN, ^ref, :process, ^stub, :normal}, 1_000
    assert Events.get(event_id).status == :partial
  end

  # A lane owner that is registered again after every stop is a crash loop, and
  # the pass must not report it reaped: a re-created id would find the
  # surviving old-generation producer.
  test "a lane owner that keeps re-registering fails the pass", %{camera_id: camera_id} do
    start_supervised!({Cairn.RespawningTrackerStub, camera_id: camera_id})

    on_exit(fn ->
      case Registry.whereis(camera_id, :camera_tracker) do
        nil -> :ok
        pid -> Process.exit(pid, :kill)
      end
    end)

    reaper = private_reaper()
    ref = Process.monitor(reaper)

    send(
      reaper,
      {:config_changed,
       diff(%{
         removed: [camera_id],
         known: Cairn.SnapshotHelpers.known_ids_excluding(camera_id)
       })}
    )

    assert_receive {:DOWN, ^ref, :process, ^reaper, {%RuntimeError{message: message}, _stack}},
                   5_000

    assert message =~ camera_id
  end

  # `Task.async_stream/3` reports a callback that raised as `{:exit, reason}`
  # in its results and nowhere else: run for effect alone, the pass would
  # return having ended nothing. The corrupt `max_scores`
  # below stands for any crash inside `end_partial/1`.
  test "an end_partial that raises fails the pass", %{camera_id: camera_id} do
    event_id = active_row!(camera_id, %{"max_scores" => "not a map"})

    start_supervised!(
      {Cairn.SlowExtractorStub, camera_id: camera_id, event_id: event_id, finalize_ms: 0}
    )

    reaper = private_reaper()
    ref = Process.monitor(reaper)

    send(
      reaper,
      {:config_changed,
       diff(%{
         removed: [camera_id],
         known: Cairn.SnapshotHelpers.known_ids_excluding(camera_id)
       })}
    )

    # The task's own exit reason, forwarded intact: `Task.async_stream/3`
    # reports a raise in Erlang form, not as the `%BadMapError{}` struct.
    assert_receive {:DOWN, ^ref, :process, ^reaper, {{:badmap, "not a map"}, _stack}}, 5_000
  end

  # `:temporary` so the crash each of these tests provokes is not answered by
  # a restart the test would then have to reason about, and unnamed so it does
  # not contend with the application's own reaper for the name.
  defp private_reaper do
    start_supervised!(%{
      id: :private_reaper,
      restart: :temporary,
      start: {CameraReaper, :start_link, [[name: nil]]}
    })
  end

  # A bare process registered under a lane role, stopped the same way a real
  # lane owner is: `stop_pid/4` finds no pool child for it and falls back to a
  # direct `GenServer.stop(_, :normal)`, which an Agent answers with `:normal`.
  defp start_lane_owner(camera_id, role) do
    start_supervised!(%{
      id: {:lane_owner_stub, role},
      restart: :temporary,
      start: {Agent, :start_link, [fn -> {:ok, _} = Registry.register(camera_id, role) end]}
    })
  end

  defp active_row!(camera_id, labels \\ %{}) do
    event_id = Ecto.UUID.generate()

    %Cairn.Events.Event{}
    |> Cairn.Events.Event.changeset(%{
      id: event_id,
      camera_id: camera_id,
      started_at: DateTime.utc_now(),
      status: :active,
      path: Path.join(System.tmp_dir!(), "#{event_id}.mp4"),
      labels: labels
    })
    |> Cairn.Repo.insert!()

    event_id
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

  defp diff(fields) do
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
  end

  defp prune(fields) do
    # `:sys.get_state/1` is what orders the prune, which runs in the reaper's
    # process, against the assertions below it. Its own delete is one id, but
    # in the full suite it must also outlast every other suite's fixture
    # lane owners, so the wait gets a generous timeout.
    send(CameraReaper, {:config_changed, diff(fields)})
    :sys.get_state(CameraReaper, 15_000)
    :ok
  end
end
