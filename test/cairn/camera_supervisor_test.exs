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

  test "apply_diff restarts changed cameras and applies adds/removals" do
    a = camera("cs_a_#{System.unique_integer([:positive])}")
    b = camera("cs_b_#{System.unique_integer([:positive])}")
    c = camera("cs_c_#{System.unique_integer([:positive])}")

    :ok = CameraSupervisor.sync(config([a, b]))
    old_b = Cairn.Registry.whereis(b.id, :camera)

    diff = %{added: [c.id], removed: [a.id], changed: [b.id], refreshed: []}
    new_config = config([%Camera{b | rtsp_url: "file:///dev/zero"}, c])
    :ok = CameraSupervisor.apply_diff(diff, new_config)

    refute Cairn.Registry.whereis(a.id, :camera)
    assert Cairn.Registry.whereis(c.id, :camera)

    new_b = wait_new_pid(b.id, old_b)
    assert is_pid(new_b)
    assert new_b != old_b
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
    assert diff == %{added: [], removed: [], changed: [], refreshed: [id]}

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

    diff = %{added: [], removed: [], changed: [], refreshed: [plain.id, "never_started"]}

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

  # Flunks rather than returning nil: a "restarted" assertion that compares
  # against the old pid passes trivially on nil.
  defp wait_new_pid(id, old, attempts \\ 100) do
    case Cairn.Registry.whereis(id, :camera) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_new_pid(id, old, attempts - 1)

      _ ->
        flunk("camera #{id} never came back with a new pid (was #{inspect(old)})")
    end
  end
end
