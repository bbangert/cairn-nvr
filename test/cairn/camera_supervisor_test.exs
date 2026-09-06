defmodule Cairn.CameraSupervisorTest do
  # drives the real DynamicSupervisor + Camera trees (ffmpeg mostly spawns
  # against an instantly-failing file source; backoff keeps the noise to one
  # spawn — the streaming test uses a real fixture and runs to completion)
  use ExUnit.Case, async: false

  alias Cairn.CameraSupervisor
  alias Cairn.Config
  alias Cairn.Config.Camera

  setup do
    # the sh wrapper appends every subprocess's stderr here
    File.mkdir_p!("tmp/camsup_test/log")
    # Registered first so LIFO runs it last, after the cameras are stopped
    on_exit(fn -> File.rm_rf!("tmp/camsup_test") end)
    Application.put_env(:cairn, :start_cameras, true)
    on_exit(fn -> Application.put_env(:cairn, :start_cameras, false) end)

    on_exit(fn ->
      Enum.each(Cairn.Registry.ids_for_role(:camera), &CameraSupervisor.stop_camera/1)
    end)

    :ok
  end

  defp camera(id), do: %Camera{id: id, rtsp_url: "file:///dev/null"}

  defp config(cameras) do
    %Config{data_dir: "tmp/camsup_test", cameras: cameras}
  end

  # A camera whose resolved tier is `tier`, which is what `Cairn.Camera.Lane`
  # composes from. The tier lives on the group's profile, never on the camera,
  # so a tiered fixture is a camera plus the group it points at.
  defp tiered(id, tier) do
    group = "tier#{tier}"

    {%Camera{camera(id) | plugin: {:group, group}},
     %Cairn.Config.PluginGroup{
       name: group,
       profile: %Cairn.Config.Profile{name: group, tier: tier}
     }}
  end

  defp tiered_config(pairs) do
    %Config{
      config(Enum.map(pairs, &elem(&1, 0)))
      | plugin_groups: Enum.map(pairs, &elem(&1, 1))
    }
  end

  test "sync starts missing cameras, is idempotent, and stops removed ones" do
    a = camera("cs_a_#{System.unique_integer([:positive])}")
    b = camera("cs_b_#{System.unique_integer([:positive])}")

    :ok = CameraSupervisor.sync(config([a, b]))
    assert Cairn.Registry.whereis(a.id, :camera)
    assert Cairn.Registry.whereis(b.id, :camera)
    pid_a = Cairn.Registry.whereis(a.id, :camera)

    # idempotent: same pid, no crash on already_started
    :ok = CameraSupervisor.sync(config([a, b]))
    assert Cairn.Registry.whereis(a.id, :camera) == pid_a

    # removed from config -> stopped on next sync
    :ok = CameraSupervisor.sync(config([b]))
    refute Cairn.Registry.whereis(a.id, :camera)
    assert Cairn.Registry.whereis(b.id, :camera)
  end

  test "apply_diff replaces a changed camera's media and applies adds/removals" do
    a = camera("cs_a_#{System.unique_integer([:positive])}")
    b = camera("cs_b_#{System.unique_integer([:positive])}")
    c = camera("cs_c_#{System.unique_integer([:positive])}")

    :ok = CameraSupervisor.sync(config([a, b]))
    sup_b = Cairn.Registry.whereis(b.id, :camera)
    old_media = child_pid(sup_b, :media)
    old_lane = child_pid(sup_b, :lane)

    diff = %{added: [c.id], removed: [a.id], changed: [b.id], rebuilt: [], refreshed: []}
    new_config = config([%Camera{b | rtsp_url: "file:///dev/zero"}, c])
    :ok = CameraSupervisor.apply_diff(diff, new_config)

    refute Cairn.Registry.whereis(a.id, :camera)
    assert Cairn.Registry.whereis(c.id, :camera)

    # a restart-class change is media-only: the camera's supervisor, its
    # Registry name and its lane are the same processes afterwards
    assert Cairn.Registry.whereis(b.id, :camera) == sup_b
    assert Process.alive?(sup_b)
    assert child_pid(sup_b, :lane) == old_lane

    new_media = child_pid(sup_b, :media)
    assert new_media != old_media
    refute Process.alive?(old_media)

    # and it was built from the NEW camera, not the struct the tree was born with
    owner = Cairn.Registry.whereis(b.id, :pipeline)
    assert :sys.get_state(owner).camera.rtsp_url == "file:///dev/zero"
  end

  test "a camera rebuilt by its DynamicSupervisor comes back on the changed config" do
    b = camera("cs_rebuild_#{System.unique_integer([:positive])}")
    :ok = CameraSupervisor.sync(config([b]))
    sup = Cairn.Registry.whereis(b.id, :camera)

    new_config = config([%Camera{b | rtsp_url: "file:///dev/zero"}])
    # what the server publishes before it calls apply_diff — the only record of
    # the change a whole-tree rebuild can read, since `DynamicSupervisor` keeps
    # the spec this camera was started with
    publish(new_config)
    diff = %{added: [], removed: [], changed: [b.id], rebuilt: [], refreshed: []}
    :ok = CameraSupervisor.apply_diff(diff, new_config)

    # What a media crash-loop past `Cairn.Camera`'s own intensity ends in: the
    # camera's supervisor exits and `CameraSupervisor` restarts it (`:permanent`)
    # from the spec it stored, which still names the pre-change camera. Stopped
    # rather than killed so the old tree's Registry names are gone first — a
    # rebuild racing them would only fail to start.
    Supervisor.stop(sup, :shutdown)
    Cairn.Registry.await_unregistered(b.id, :camera)

    owner = wait_for(fn -> Cairn.Registry.whereis(b.id, :pipeline) end)
    assert is_pid(owner)
    assert :sys.get_state(owner).camera.rtsp_url == "file:///dev/zero"
  end

  test "a changed camera whose new media will not start is stopped, not left dark" do
    id = "cs_badmedia_#{System.unique_integer([:positive])}"
    :ok = CameraSupervisor.sync(config([camera(id)]))
    assert Cairn.Registry.whereis(id, :camera)

    # Hold the new media's first Registry name from this process, so its
    # `RingBuffer` cannot register and the subtree's start fails. The old media
    # has to be down first — the name is unique, and Registry only evicts a
    # dead owner. Held by a *live* process on purpose: the registry evicts a
    # stale entry whose owner is dead rather than refusing the registration,
    # so a dead holder would not fail the start at all.
    sup = Cairn.Registry.whereis(id, :camera)
    :ok = Supervisor.terminate_child(sup, :media)
    Cairn.Registry.await_unregistered(id, :ring_buffer)
    {:ok, _} = Registry.register(Cairn.Registry, {id, :ring_buffer}, nil)

    ExUnit.CaptureLog.capture_log(fn ->
      :ok = CameraSupervisor.restart_media(config([camera(id)]), id)
    end)

    refute Cairn.Registry.whereis(id, :camera)
  end

  test "a media replacement is not stopped by names the registry has not reaped" do
    id = "cs_stale_#{System.unique_integer([:positive])}"
    cfg = config([camera(id)])
    :ok = CameraSupervisor.sync(cfg)
    sup = Cairn.Registry.whereis(id, :camera)
    old_media = child_pid(sup, :media)

    # Registry unregisters on the owner's DOWN, handled by the partition
    # process below — a `terminate_child` can return before it runs. Suspended,
    # that lag is
    # unbounded and the state below is the one `restart_media/2` would race:
    # every media name still in the table, every owner dead. Resumed first on
    # the way out, ahead of the setup's camera teardown.
    partition = Process.whereis(Cairn.Registry.PIDPartition0)
    assert is_pid(partition)
    :sys.suspend(partition)
    on_exit(fn -> :sys.resume(partition) end)

    :ok = Supervisor.terminate_child(sup, :media)

    for role <- [:ring_buffer, :ffmpeg, :pipeline, :rtp_hub] do
      pid = Cairn.Registry.whereis(id, role)
      assert is_pid(pid) and not Process.alive?(pid), "#{role} was reaped, not stale"
    end

    :ok = CameraSupervisor.restart_media(cfg, id)

    # `Registry.register/3` drops a unique entry whose owner is dead and
    # retries, so the new chain takes each name rather than being refused it —
    # no name is awaited in between, and the camera is not stopped.
    assert Cairn.Registry.whereis(id, :camera) == sup
    assert child_pid(sup, :media) != old_media
    owner = Cairn.Registry.whereis(id, :pipeline)
    assert is_pid(owner) and Process.alive?(owner)
  end

  test "a camera tree nests an empty lane alongside its media" do
    a = camera("cs_nest_#{System.unique_integer([:positive])}")
    :ok = CameraSupervisor.sync(config([a]))
    sup = Cairn.Registry.whereis(a.id, :camera)

    children = Supervisor.which_children(sup)

    assert MapSet.new(children, fn {id, _pid, _type, _mods} -> id end) ==
             MapSet.new([:lane, :media])

    assert {:lane, _pid, :supervisor, [Cairn.Camera.Lane]} = List.keyfind(children, :lane, 0)
    assert {:media, _pid, :supervisor, [Cairn.Camera.Media]} = List.keyfind(children, :media, 0)

    # this camera resolves to no tier, so it runs no event workers yet
    assert Supervisor.which_children(child_pid(sup, :lane)) == []
  end

  test "a tier-1 camera's lane runs the recorder and then the aggregator" do
    {cam, group} = tiered("cs_t1_#{System.unique_integer([:positive])}", 1)
    :ok = CameraSupervisor.sync(tiered_config([{cam, group}]))
    sup = Cairn.Registry.whereis(cam.id, :camera)

    # The recorder starts first so it is listening when the aggregator's
    # `init/1` clears its predecessor's announced keys (`Cairn.Camera.Lane`).
    # `which_children/1` answers in reverse, which is also the shutdown order.
    assert [{Cairn.PresenceAggregator, _agg, _, _}, {Cairn.PresenceRecorder, _rec, _, _}] =
             Supervisor.which_children(child_pid(sup, :lane))

    assert Cairn.Registry.whereis(cam.id, :presence)
    assert Cairn.Registry.whereis(cam.id, :presence_recorder)
  end

  test "a tier-2 camera's lane is empty" do
    {cam, group} = tiered("cs_t2_#{System.unique_integer([:positive])}", 2)
    :ok = CameraSupervisor.sync(tiered_config([{cam, group}]))
    sup = Cairn.Registry.whereis(cam.id, :camera)

    assert Supervisor.which_children(child_pid(sup, :lane)) == []
    refute Cairn.Registry.whereis(cam.id, :presence)
    refute Cairn.Registry.whereis(cam.id, :presence_recorder)
  end

  # The survival property the media/lane split exists for, and the deliberate
  # reversal of the old behaviour: `restart_media/2` used to retire the
  # aggregator in the gap. A restart-class change cannot move the tier — a tier
  # flip is `rebuilt` — so the presence workers outlive the new pipeline
  # exactly as they outlive a reconnect.
  # What survives a media replacement and what does not. The lane's workers do,
  # with their presence state; the open CLIP does not, because the ring feeding
  # it is inside `:media` and the extractor's subscription is held by that ring
  # alone. So the first clip ends `:finalized` at the replacement and the next
  # opens on the new ring, with the same recorder holding the same keys
  # throughout.
  test "a media-only change keeps the tier-1 lane and splits its open clip" do
    {cam, group} = tiered("cs_survive_#{System.unique_integer([:positive])}", 1)
    id = cam.id
    cfg = tiered_config([{cam, group}])
    publish(cfg)
    Cairn.Event.subscribe()

    :ok = CameraSupervisor.sync(cfg)
    sup = Cairn.Registry.whereis(id, :camera)
    agg = Cairn.Registry.whereis(id, :presence)
    rec = Cairn.Registry.whereis(id, :presence_recorder)
    old_media = child_pid(sup, :media)
    assert wait_for(fn -> Cairn.Registry.whereis(id, :ring_buffer) end, 200)

    # a clip open on the ring the replacement is about to take, through a stand
    # -in extractor that holds the ring subscription the real one would
    extractor = ring_subscriber(id)
    event = open_event(id)
    eid = event.id
    Cairn.PresenceLedger.announced(id, nil, "person", DateTime.utc_now(), 0.9)
    on_exit(fn -> Cairn.PresenceLedger.cleared(id, nil, "person") end)
    Cairn.PresenceCheckpoint.put!(id, event, [{nil, "person"}], extractor)
    on_exit(fn -> Cairn.PresenceCheckpoint.delete(id) end)

    Process.exit(rec, :kill)
    restored = wait_for(fn -> replacement(id, rec) end, 400)
    assert :sys.get_state(restored).event.id == eid

    moved = %Camera{cam | rtsp_url: "file:///dev/zero"}
    new_config = tiered_config([{moved, group}])
    publish(new_config)
    diff = %{added: [], removed: [], changed: [id], rebuilt: [], refreshed: []}
    :ok = CameraSupervisor.apply_diff(diff, new_config)

    # the workers are the same processes, and answering
    assert child_pid(sup, :media) != old_media
    assert Cairn.Registry.whereis(id, :presence) == agg
    assert Cairn.Registry.whereis(id, :presence_recorder) == restored
    # answering a call is liveness `Process.alive?/1` cannot claim: a pid that
    # has already exited can still read as alive for a moment
    assert is_map(:sys.get_state(agg))

    # the clip did not: its ring went with the old media, so the stand-in saw
    # the DOWN a real extractor closes on, and the recorder let the event go
    assert_receive {:ring_gone, ^extractor}, 2_000
    assert wait_for_state(restored, &(&1.event == nil))
    state = :sys.get_state(restored)
    assert MapSet.member?(state.present_labels, {nil, "person"})
    assert state.retry_token != nil
  end

  # A stand-in for the extractor's half of the contract: it takes the same
  # subscription on the same ring and reports the `:DOWN` that a real one
  # closes its clip on, then exits — which is what the recorder reads. It
  # stands in rather than proves: the monitor the real extractor takes is
  # pinned in `Cairn.PresenceRecorderRestoreTest`, which has the index the
  # `:finalized` decision is read from and which this suite has not. What is
  # proved here is the consequence — the lane's workers keep their pids and
  # their keys across a media replacement while the clip does not.
  defp ring_subscriber(camera_id) do
    test_pid = self()

    pid =
      spawn(fn ->
        {:ok, %{owner: ring}} = Cairn.RingBuffer.drain_and_subscribe(camera_id, nil, self())
        ref = Process.monitor(ring)
        send(test_pid, {:subscribed, self()})

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> send(test_pid, {:ring_gone, self()})
        end
      end)

    assert_receive {:subscribed, ^pid}
    pid
  end

  # A lane worker's `init/1` may not call `Cairn.Config.Server`, because that
  # is exactly who starts it: a reload or a save that adds or rebuilds a
  # tier-1 camera runs `apply_diff/2` → `sync/1` → `start_camera/2` →
  # `Cairn.Camera.init/1` → `Cairn.Camera.Lane.init/1` → the recorder's
  # `init/1`, all inside the server's own `handle_call`. A call back would wait
  # on a process waiting on it.
  #
  # Suspended is that server's state, exactly: inside a call it cannot answer
  # another. So the tree is started against a suspended config server, and what
  # is asserted is that it comes up anyway — from the snapshot the server
  # publishes BEFORE it applies a diff, which is what both `Cairn.Camera` and
  # the recorder read.
  test "a tier-1 lane starts while the config server cannot answer a call" do
    {cam, group} = tiered("cs_nocall_#{System.unique_integer([:positive])}", 1)
    id = cam.id
    cfg = tiered_config([{cam, group}])
    publish(cfg)

    :sys.suspend(Cairn.Config.Server)
    on_exit(fn -> :sys.resume(Cairn.Config.Server) end)

    started_at = System.monotonic_time(:millisecond)
    :ok = CameraSupervisor.sync(cfg)
    rec = wait_for(fn -> Cairn.Registry.whereis(id, :presence_recorder) end, 200)
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert is_pid(rec)
    assert Cairn.Registry.whereis(id, :presence)
    # promptly, not after a call timed out
    assert elapsed < 1_000, "the lane took #{elapsed}ms to come up"
    # and it resolved a real policy from the snapshot, not the seeded default
    assert is_map(:sys.get_state(rec).policy)

    # the same for a tier flip, which `rebuilt` routes through a whole-tree stop
    # and start — the second place a lane is born inside that call
    {cam2, group2} = tiered(id, 2)
    tier2 = tiered_config([{cam2, group2}])
    # published first, as the server does — the tree resolves from the snapshot
    publish(tier2)
    :ok = CameraSupervisor.apply_diff(rebuilt_diff(id), tier2)
    refute Cairn.Registry.whereis(id, :presence_recorder)

    publish(cfg)

    :ok = CameraSupervisor.apply_diff(rebuilt_diff(id), cfg)
    back = wait_for(fn -> Cairn.Registry.whereis(id, :presence_recorder) end, 200)
    assert is_pid(back) and back != rec
  end

  # The same rule one process further down. A leftover ledger row makes the
  # recorder open an event inside its own `init/1`, and that starts a real
  # `Cairn.EventExtractor`, whose own default reads the config by CALLING the
  # server — the second door into the same deadlock. A lane worker restarting
  # on its own is where this is reachable: the media is up, so the ring gate is
  # open and the restore really does open a clip.
  test "a restore-driven open starts an extractor without calling the config server" do
    {cam, group} = tiered("cs_exconf_#{System.unique_integer([:positive])}", 1)
    id = cam.id

    # A real extractor writes a clip, so it gets a data dir of its own rather
    # than the suite's shared one: it has no sandbox connection here, so its
    # first row fails and it exits — and a file it creates under a directory
    # the setup's `on_exit` is removing races that removal.
    dir = Path.join(System.tmp_dir!(), "cairn_exconf_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    cfg = %Config{tiered_config([{cam, group}]) | data_dir: dir}
    publish(cfg)
    Cairn.Event.subscribe()

    :ok = CameraSupervisor.sync(cfg)
    rec = wait_for(fn -> Cairn.Registry.whereis(id, :presence_recorder) end, 200)
    assert wait_for(fn -> Cairn.Registry.whereis(id, :ring_buffer) end, 200)

    # the announced key its replacement will adopt, as an aggregator that is
    # still running left it
    Cairn.PresenceLedger.announced(id, nil, "person", DateTime.utc_now(), 0.9)
    on_exit(fn -> Cairn.PresenceLedger.cleared(id, nil, "person") end)

    :sys.suspend(Cairn.Config.Server)
    on_exit(fn -> :sys.resume(Cairn.Config.Server) end)

    started_at = System.monotonic_time(:millisecond)
    Process.exit(rec, :kill)
    assert is_pid(wait_for(fn -> replacement(id, rec) end, 400))
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert elapsed < 1_000, "the lane took #{elapsed}ms to come back"

    # The adopted key opened a clip, promptly — a real `Cairn.EventExtractor`
    # started and answered. Whether it stays alive is not asserted: this suite
    # has no database, so its first write fails and it exits. The open landing
    # at all is the contract; with the config left to the extractor's own
    # `Cairn.Config.Server.get/0` it never lands while the server is blocked.
    assert_receive {:event_started, %Cairn.Event{camera_id: ^id} = event}, 2_000

    # awaited, so nothing is still writing when this test's directory goes
    await_extractor_gone(id, event.id)
  end

  # No ring, no clip. A whole-camera start brings the `:lane` up ahead of
  # `:media` by design, so a restored key reaches the open before
  # `Cairn.RingBuffer` holds its name — and the extractor drains that ring in
  # its own `handle_continue`. Opening anyway cost an `:event_ended`
  # `:partial` for a clip that never began, once per camera-tree start with a
  # standing presence.
  test "a whole lane starting ahead of the media announces no clip it cannot fill" do
    {cam, group} = tiered("cs_noring_#{System.unique_integer([:positive])}", 1)
    id = cam.id
    cfg = tiered_config([{cam, group}])
    publish(cfg)
    Cairn.Event.subscribe()

    Cairn.PresenceLedger.announced(id, nil, "person", DateTime.utc_now(), 0.9)
    on_exit(fn -> Cairn.PresenceLedger.cleared(id, nil, "person") end)

    # the lane alone, exactly as `Cairn.Camera` starts it before `:media`
    start_supervised!({Cairn.Camera.Lane, camera: cam, config: cfg}, id: :bare_lane)

    rec = Cairn.Registry.whereis(id, :presence_recorder)
    assert is_pid(rec)
    refute Cairn.Registry.whereis(id, :ring_buffer)

    # The recorder adopted the announced key and deferred; the aggregator,
    # starting behind it, cleared the same key — so the stay ends with no
    # event at all, where before it ended with a junk `:partial` for a clip
    # the extractor never opened.
    assert_receive {:presence_cleared, %Cairn.PresenceEvent{camera_id: ^id, label: "person"}}
    assert :sys.get_state(rec).event == nil
    refute_received {:event_started, %Cairn.Event{camera_id: ^id}}
    refute_received {:event_ended, %Cairn.Event{camera_id: ^id}}
  end

  # The deferral is a wait, not a refusal: the retry loop the gate arms is what
  # opens the clip once the ring is up. Driven on the recorder alone, which is
  # the lane-restart shape — with the whole lane starting, the aggregator's
  # own restore clears the adopted key first (the case above).
  test "a deferred open is retried once the ring buffer arrives" do
    {cam, group} = tiered("cs_ringwait_#{System.unique_integer([:positive])}", 1)
    id = cam.id
    publish(tiered_config([{cam, group}]))
    Cairn.Event.subscribe()

    Cairn.PresenceLedger.announced(id, nil, "person", DateTime.utc_now(), 0.9)
    on_exit(fn -> Cairn.PresenceLedger.cleared(id, nil, "person") end)

    # The extractor is stubbed: what this proves is that the RETRY opens once
    # the ring is there, not that a clip is written — and a real one would
    # write an `:active` row this suite has no sandbox for, then crash, having
    # already created files under the data dir the setup's `on_exit` is
    # removing.
    rec =
      start_supervised!({Cairn.PresenceRecorder, [camera: cam] ++ stub_extractor()},
        id: :bare_recorder
      )

    refute Cairn.Registry.whereis(id, :ring_buffer)

    state = :sys.get_state(rec)
    assert state.event == nil
    assert MapSet.member?(state.present_labels, {nil, "person"})
    assert state.retry_token != nil
    refute_received {:event_started, %Cairn.Event{camera_id: ^id}}
    refute_received {:event_ended, %Cairn.Event{camera_id: ^id}}

    # the ring arrives, as `:media` starting behind the lane brings it
    start_supervised!({Cairn.RingBuffer, camera_id: id, pre_window_seconds: 5}, id: :late_ring)
    send(rec, {:retry_open, :sys.get_state(rec).retry_token})

    assert_receive {:event_started, %Cairn.Event{camera_id: ^id}}, 2_000
    assert_receive {:extractor_started, %Cairn.Event{camera_id: ^id}, _relay}
  end

  # `Cairn.Registry.whereis/2` does not filter dead pids, and the single
  # partition's DOWN handling can lag a read: inside a media replacement a
  # `:retry_open` timer can see the old ring's corpse. Answering it would open
  # a clip against a ring that cannot be drained.
  test "a ring the registry has not reaped yet does not open the gate" do
    {cam, group} = tiered("cs_deadring_#{System.unique_integer([:positive])}", 1)
    id = cam.id
    publish(tiered_config([{cam, group}]))
    Cairn.Event.subscribe()

    ring = start_supervised!({Cairn.RingBuffer, camera_id: id, pre_window_seconds: 5}, id: :ring)

    rec =
      start_supervised!({Cairn.PresenceRecorder, [camera: cam] ++ stub_extractor()},
        id: :gate_recorder
      )

    # Suspended, the registry's unregistration lag is unbounded, which is the
    # state a read inside a media replacement can land in. Resumed on the way
    # out, ahead of this suite's camera teardown.
    partition = Process.whereis(Cairn.Registry.PIDPartition0)
    :sys.suspend(partition)
    on_exit(fn -> :sys.resume(partition) end)

    :ok = stop_supervised(:ring)
    refute Process.alive?(ring)
    assert Cairn.Registry.whereis(id, :ring_buffer) == ring

    Cairn.PresenceRecorder.presence(id, :presence_started, %Cairn.PresenceEvent{
      camera_id: id,
      zone: nil,
      label: "person",
      score: 0.9,
      first_seen_at: DateTime.utc_now(),
      at: DateTime.utc_now()
    })

    state = :sys.get_state(rec)
    assert state.event == nil
    assert state.retry_token != nil
    refute_received {:extractor_started, %Cairn.Event{camera_id: ^id}, _relay}
    refute_received {:event_started, %Cairn.Event{camera_id: ^id}}
  end

  # The one path S2 changes on a running node, through the real tree: a tier-1
  # camera with a clip open leaves the config, `apply_diff` stops its tree, and
  # the lane's reverse-order teardown clears the presence and finalizes the
  # event. Nothing is stubbed but the extractor, which stands in as a plain
  # process so this suite needs no database — what it has to prove is that the
  # RECORDER cast the finalize on the way out, and that the row and the names
  # are gone with the camera.
  test "removing a tier-1 camera finalizes its open event and takes the lane with it" do
    {cam, group} = tiered("cs_del_#{System.unique_integer([:positive])}", 1)
    id = cam.id
    test_pid = self()
    cfg = tiered_config([{cam, group}])
    # The snapshot, not `Cairn.SnapshotHelpers.lend_cameras/1`: `Cairn.Camera`
    # resolves its tree from the published config, and a lent bare camera would
    # shadow the group this one's tier comes from — an empty lane.
    publish(cfg)
    Cairn.Event.subscribe()

    :ok = CameraSupervisor.sync(cfg)
    rec = Cairn.Registry.whereis(id, :presence_recorder)
    assert is_pid(rec)
    assert Cairn.Registry.whereis(id, :presence)

    # An open event on the real recorder, in the shape a restore produces: a
    # live extractor it adopts, and the ledger row its aggregator would have
    # left. Driving detections instead would need the model and the database
    # this suite deliberately does without.
    extractor = Cairn.PresenceFixtures.relay(test_pid)
    event = open_event(id)
    eid = event.id
    Cairn.PresenceLedger.announced(id, nil, "person", DateTime.utc_now(), 0.9)
    Cairn.PresenceCheckpoint.put!(id, event, [{nil, "person"}], extractor)
    on_exit(fn -> Cairn.PresenceCheckpoint.delete(id) end)

    # the restore happens in `init/1`, so the recorder is replaced rather than
    # told — a crash of the one the lane started is the ordinary way in
    Process.exit(rec, :kill)
    restored = wait_for(fn -> replacement(id, rec) end)
    assert :sys.get_state(restored).event.id == eid

    # …and a live presence in the aggregator, so its own teardown has something
    # to clear. Two sightings inside the confirm window is what a confirm is.
    base = System.monotonic_time(:millisecond)
    Cairn.PresenceAggregator.observed(id, base, %{{nil, "person"} => 0.9})
    Cairn.PresenceAggregator.observed(id, base + 500, %{{nil, "person"} => 0.9})
    assert_receive {:presence_started, %Cairn.PresenceEvent{camera_id: ^id}}

    diff = %{added: [], removed: [id], changed: [], rebuilt: [], refreshed: []}
    :ok = CameraSupervisor.apply_diff(diff, config([]))

    # reverse order: the aggregator cleared into a live recorder, and the
    # recorder's own stop is what finalized
    assert_receive {:presence_cleared, %Cairn.PresenceEvent{camera_id: ^id, label: "person"}}
    assert_receive {:event_ended, %Cairn.Event{id: ^eid, status: :finalized}}
    # and the finalize was cast by the recorder itself, to its own extractor
    assert_receive {:extractor_cast, {:finalize, %Cairn.Event{id: ^eid}}}

    refute Cairn.Registry.whereis(id, :camera)
    refute Cairn.Registry.whereis(id, :presence)
    refute Cairn.Registry.whereis(id, :presence_recorder)
    assert Cairn.PresenceCheckpoint.get(id) == nil
  end

  # The lane's composition is a child list, which no running supervisor can be
  # edited into — so a tier flip is the whole tree, not the media.
  test "a rebuilt camera's whole tree is replaced, where a changed one's is not" do
    {cam, group} = tiered("cs_flip_#{System.unique_integer([:positive])}", 1)
    :ok = CameraSupervisor.sync(tiered_config([{cam, group}]))

    sup = Cairn.Registry.whereis(cam.id, :camera)
    assert Cairn.Registry.whereis(cam.id, :presence)

    {_cam2, tier2_group} = tiered(cam.id, 2)
    flipped = %Camera{cam | plugin: {:group, tier2_group.name}}
    new_config = tiered_config([{flipped, tier2_group}])

    assert %{changed: [], rebuilt: [id], refreshed: []} =
             Config.Server.diff_cameras(tiered_config([{cam, group}]), new_config)

    assert id == cam.id

    :ok =
      CameraSupervisor.apply_diff(
        %{added: [], removed: [], changed: [], rebuilt: [cam.id], refreshed: []},
        new_config
      )

    new_sup = Cairn.Registry.whereis(cam.id, :camera)
    assert is_pid(new_sup) and new_sup != sup
    refute Process.alive?(sup)
    # and the tree it came back as is the new tier's: no presence workers
    assert Supervisor.which_children(child_pid(new_sup, :lane)) == []
    refute Cairn.Registry.whereis(cam.id, :presence)
  end

  test "a removed camera stops its whole tree, lane and media with it" do
    id = "cs_gone_#{System.unique_integer([:positive])}"
    old = config([camera(id)])

    :ok = CameraSupervisor.sync(old)
    sup = Cairn.Registry.whereis(id, :camera)
    lane = child_pid(sup, :lane)
    media = child_pid(sup, :media)

    diff = %{added: [], removed: [id], changed: [], rebuilt: [], refreshed: []}
    :ok = CameraSupervisor.apply_diff(diff, config([]))

    refute Cairn.Registry.whereis(id, :camera)
    refute Process.alive?(sup)
    refute Process.alive?(lane)
    refute Process.alive?(media)
  end

  test "apply_diff refreshes a camera in place instead of restarting it" do
    id = "cs_refresh_#{System.unique_integer([:positive])}"
    cam = camera(id)
    old = config([cam])

    :ok = CameraSupervisor.sync(old)
    camera_pid = Cairn.Registry.whereis(id, :camera)
    owner_pid = Cairn.Registry.whereis(id, :pipeline)
    assert is_pid(owner_pid)

    # a global window edit reaches no argv, so the camera keeps its stream —
    # and with it every live track on the camera
    new = %Config{old | post_window_seconds: 42}
    diff = Config.Server.diff_cameras(old, new)
    assert diff == %{added: [], removed: [], changed: [], rebuilt: [], refreshed: [id]}

    :ok = CameraSupervisor.apply_diff(diff, new)

    assert Cairn.Registry.whereis(id, :camera) == camera_pid
    assert Cairn.Registry.whereis(id, :pipeline) == owner_pid
    # the cast is flushed by this call, which is also how it is ordered after
    # the one apply_diff sent (both from this process)
    assert :sys.get_state(owner_pid).config.post_window_seconds == 42
  end

  test "refreshing an id the config does not carry leaves the running camera alone" do
    id = "cs_absent_#{System.unique_integer([:positive])}"

    :ok = CameraSupervisor.sync(config([camera(id)]))
    owner_pid = Cairn.Registry.whereis(id, :pipeline)
    assert is_pid(owner_pid)

    # `apply_diff/2` cannot produce this — a `refreshed` id is by construction
    # in both configs — but the camera is running and the id is gone, and the
    # `with` has to answer :ok rather than hand the owner a `nil` camera
    assert :ok = CameraSupervisor.refresh_camera(config([]), id)
    assert Cairn.Registry.whereis(id, :pipeline) == owner_pid
    assert %Camera{id: ^id} = :sys.get_state(owner_pid).camera
  end

  test "refreshing a camera that is not running is a no-op" do
    plain = camera("cs_pref_#{System.unique_integer([:positive])}")
    new_config = config([plain])

    :ok = CameraSupervisor.sync(new_config)
    pid = Cairn.Registry.whereis(plain.id, :camera)

    diff = %{
      added: [],
      removed: [],
      changed: [],
      rebuilt: [],
      refreshed: [plain.id, "never_started"]
    }

    assert :ok = CameraSupervisor.apply_diff(diff, new_config)
    assert Cairn.Registry.whereis(plain.id, :camera) == pid
  end

  test "stop_camera on an unknown id is a no-op" do
    assert :ok = CameraSupervisor.stop_camera("never_started")
  end

  test "camera tree registers ring buffer, bridge port, pipeline owner and rtp hub" do
    a = camera("cs_tree_#{System.unique_integer([:positive])}")
    :ok = CameraSupervisor.sync(config([a]))

    assert Cairn.Registry.whereis(a.id, :ring_buffer)
    assert Cairn.Registry.whereis(a.id, :ffmpeg)
    assert Cairn.Registry.whereis(a.id, :pipeline)
    assert Cairn.Registry.whereis(a.id, :rtp_hub)
  end

  test "an rtsp-ingest camera has no bridge port: its sessions live in the source" do
    a = %Camera{
      camera("cs_rtsp_#{System.unique_integer([:positive])}")
      | rtsp_url: "rtsp://127.0.0.1:1/none",
        ingest: :rtsp
    }

    :ok = CameraSupervisor.sync(config([a]))

    assert Cairn.Registry.whereis(a.id, :pipeline)
    refute Cairn.Registry.whereis(a.id, :ffmpeg)
  end

  test "a camera streams through the real tree onto the ring and the hub topic" do
    id = "cs_membrane_#{System.unique_integer([:positive])}"
    fixture = Path.absname("test/support/fixtures/media/testsrc.ts")
    cam = %Camera{id: id, rtsp_url: "file://#{fixture}"}

    # subscribe before the tree starts so no init/fragment/packet is missed
    Phoenix.PubSub.subscribe(Cairn.PubSub, Cairn.RingBuffer.topic(id))
    Phoenix.PubSub.subscribe(Cairn.PubSub, Cairn.RTPHub.topic(id))

    :ok = CameraSupervisor.sync(config([cam]))
    assert Cairn.Registry.whereis(id, :camera)

    # the real pipeline, fed real ffmpeg mpegts over stdout, drives both branches:
    # CMAF fragments onto the ring and RTP packets onto the hub topic (the hub
    # owns no socket — it is fed in-process by the pipeline's RTP branch)
    assert_receive {:init_segment, %{camera_id: ^id}}, 10_000
    assert_receive {:fragment, _frag}, 10_000
    assert_receive {:rtp, %ExRTP.Packet{}}, 10_000
  end

  test "a camera referencing a plugin group starts the same tree" do
    a = %Camera{camera("cs_grp_#{System.unique_integer([:positive])}") | plugin: {:group, "det"}}
    :ok = CameraSupervisor.sync(config([a]))

    assert Cairn.Registry.whereis(a.id, :pipeline)
    assert Cairn.Registry.whereis(a.id, :rtp_hub)
  end

  # Stands in for a reload: `Cairn.Config.Server` publishes its snapshot before
  # applying the diff, and that term is what a tree rebuilt from a stale child
  # spec resolves itself from.
  defp publish(config) do
    key = Cairn.Config.Server.snapshot_key(Cairn.Config.Server)
    previous = :persistent_term.get(key, nil)
    :persistent_term.put(key, config)

    on_exit(fn ->
      if previous, do: :persistent_term.put(key, previous), else: :persistent_term.erase(key)
    end)
  end

  # The lane suites' extractor stand-in: a plain process that reports and never
  # touches the database or the data dir, which this suite has neither a
  # sandbox connection nor a lifetime for.
  defp stub_extractor do
    test_pid = self()

    [
      start_extractor: fn _camera, event, _config ->
        pid = Cairn.PresenceFixtures.relay(test_pid)
        send(test_pid, {:extractor_started, event, pid})
        {:ok, pid}
      end,
      finalize_extractor: fn pid, event -> send(test_pid, {:extractor_finalized, pid, event}) end
    ]
  end

  # A real extractor is `:temporary` under `Cairn.EventSupervisor`, outside
  # every tree this suite stops, so a test that started one waits for it before
  # its directory is removed. Already gone is the ordinary answer: with no
  # sandbox connection its first write fails.
  defp await_extractor_gone(camera_id, event_id) do
    case Cairn.Registry.whereis(camera_id, {:extractor, event_id}) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
        :ok
    end
  end

  defp wait_for_state(pid, ready?, attempts \\ 200) do
    cond do
      ready?.(:sys.get_state(pid)) -> true
      attempts > 0 -> Process.sleep(10) && wait_for_state(pid, ready?, attempts - 1)
      true -> flunk("#{inspect(pid)} never reached the expected state")
    end
  end

  defp rebuilt_diff(id),
    do: %{added: [], removed: [], changed: [], rebuilt: [id], refreshed: []}

  defp open_event(camera_id) do
    %Cairn.Event{
      id: Ecto.UUID.generate(),
      camera_id: camera_id,
      started_at: DateTime.add(DateTime.utc_now(), -30),
      status: :active,
      labels: [%{t: +0.0, label: "person", score: 0.9}],
      max_scores: %{"person" => 0.9},
      max_score: 0.9
    }
  end

  defp replacement(camera_id, dead) do
    case Cairn.Registry.whereis(camera_id, :presence_recorder) do
      pid when is_pid(pid) and pid != dead -> pid
      _absent_or_dead -> nil
    end
  end

  defp wait_for(fun, attempts \\ 200) do
    case fun.() do
      nil when attempts > 0 ->
        Process.sleep(5)
        wait_for(fun, attempts - 1)

      other ->
        other
    end
  end

  # Flunks rather than returning nil: a "replaced" assertion that compares
  # against the old pid passes trivially on nil.
  defp child_pid(sup, id) do
    case List.keyfind(Supervisor.which_children(sup), id, 0) do
      {^id, pid, _type, _mods} when is_pid(pid) -> pid
      other -> flunk("#{inspect(sup)} has no running #{inspect(id)} child: #{inspect(other)}")
    end
  end
end
