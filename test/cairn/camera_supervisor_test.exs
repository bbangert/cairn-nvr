defmodule Cairn.CameraSupervisorTest do
  # drives the real DynamicSupervisor + Camera trees (ffmpeg spawns against
  # an instantly-failing file source; backoff keeps the noise to one spawn)
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

  defp config(cameras, base) do
    %Config{
      data_dir: "tmp/camsup_test",
      udp_base_port: base,
      udp_port_range: 20,
      cameras: cameras
    }
  end

  test "sync starts missing cameras, is idempotent, and stops removed ones" do
    a = camera("cs_a_#{System.unique_integer([:positive])}")
    b = camera("cs_b_#{System.unique_integer([:positive])}")

    :ok = CameraSupervisor.sync(config([a, b], 19_600))
    assert Cairn.Registry.whereis(a.id, :camera)
    assert Cairn.Registry.whereis(b.id, :camera)
    pid_a = Cairn.Registry.whereis(a.id, :camera)

    # idempotent: same pid, no crash on already_started
    :ok = CameraSupervisor.sync(config([a, b], 19_600))
    assert Cairn.Registry.whereis(a.id, :camera) == pid_a

    # removed from config -> stopped on next sync
    :ok = CameraSupervisor.sync(config([b], 19_600))
    refute Cairn.Registry.whereis(a.id, :camera)
    assert Cairn.Registry.whereis(b.id, :camera)
  end

  test "apply_diff restarts changed cameras and applies adds/removals" do
    a = camera("cs_a_#{System.unique_integer([:positive])}")
    b = camera("cs_b_#{System.unique_integer([:positive])}")
    c = camera("cs_c_#{System.unique_integer([:positive])}")

    :ok = CameraSupervisor.sync(config([a, b], 19_640))
    old_b = Cairn.Registry.whereis(b.id, :camera)

    diff = %{added: [c.id], removed: [a.id], changed: [b.id], refreshed: []}
    new_config = config([%Camera{b | rtsp_url: "file:///dev/zero"}, c], 19_640)
    :ok = CameraSupervisor.apply_diff(diff, new_config)

    refute Cairn.Registry.whereis(a.id, :camera)
    assert Cairn.Registry.whereis(c.id, :camera)

    new_b = wait_new_pid(b.id, old_b)
    assert is_pid(new_b)
    assert new_b != old_b
  end

  test "apply_diff refreshes an inline-plugin camera instead of restarting it" do
    id = "cs_refresh_#{System.unique_integer([:positive])}"
    cam = %Camera{camera(id) | plugin: {:inline, ["sh", "-c", "exec sleep 30"]}}
    old = config([cam], 19_760)

    :ok = CameraSupervisor.sync(old)
    camera_pid = Cairn.Registry.whereis(id, :camera)
    plugin_pid = Cairn.Registry.whereis(id, :plugin)
    assert is_pid(plugin_pid)
    assert :sys.get_state(plugin_pid).policy.post == 10

    # the asymmetry this closes: a global window edit reaches no argv, so an
    # inline-plugin camera now behaves like a group-served one and keeps its
    # stream — and with it every live track on the camera
    new = %Config{old | post_window_seconds: 42}
    diff = Config.Server.diff_cameras(old, new)
    assert diff == %{added: [], removed: [], changed: [], refreshed: [id]}

    :ok = CameraSupervisor.apply_diff(diff, new)

    assert Cairn.Registry.whereis(id, :camera) == camera_pid
    assert Cairn.Registry.whereis(id, :plugin) == plugin_pid
    # the cast is flushed by this call, which is also how it is ordered after
    # the one apply_diff sent (both from this process)
    assert :sys.get_state(plugin_pid).policy.post == 42
  end

  test "refreshing an id the config does not carry leaves the running port alone" do
    id = "cs_absent_#{System.unique_integer([:positive])}"
    cam = %Camera{camera(id) | plugin: {:inline, ["sh", "-c", "exec sleep 30"]}}

    :ok = CameraSupervisor.sync(config([cam], 19_840))
    plugin_pid = Cairn.Registry.whereis(id, :plugin)
    assert is_pid(plugin_pid)

    # `apply_diff/2` cannot produce this — a `refreshed` id is by construction
    # in both configs — but the port is running and the id is gone, and the
    # `with` has to answer :ok rather than hand the port a `nil` camera
    assert :ok = CameraSupervisor.refresh_camera(config([], 19_840), id)
    assert Cairn.Registry.whereis(id, :plugin) == plugin_pid
    assert %Camera{id: ^id} = :sys.get_state(plugin_pid).camera
  end

  test "refreshing a camera with no plugin port of its own is a no-op" do
    grouped = %Camera{
      camera("cs_gref_#{System.unique_integer([:positive])}")
      | plugin: {:group, "det"}
    }

    plain = camera("cs_pref_#{System.unique_integer([:positive])}")
    new_config = config([grouped, plain], 19_800)

    :ok = CameraSupervisor.sync(new_config)
    pids = Enum.map([grouped, plain], &Cairn.Registry.whereis(&1.id, :camera))

    # grouped: its plugin belongs to the shared group process; plain: no
    # plugin at all; "never_started": not running. None is an error.
    diff = %{
      added: [],
      removed: [],
      changed: [],
      refreshed: [grouped.id, plain.id, "never_started"]
    }

    assert :ok = CameraSupervisor.apply_diff(diff, new_config)
    assert Enum.map([grouped, plain], &Cairn.Registry.whereis(&1.id, :camera)) == pids
  end

  test "stop_camera on an unknown id is a no-op" do
    assert :ok = CameraSupervisor.stop_camera("never_started")
  end

  test "camera tree registers ring buffer, ffmpeg and rtp hub children" do
    a = camera("cs_tree_#{System.unique_integer([:positive])}")
    :ok = CameraSupervisor.sync(config([a], 19_680))

    assert Cairn.Registry.whereis(a.id, :ring_buffer)
    assert Cairn.Registry.whereis(a.id, :ffmpeg)
    assert Cairn.Registry.whereis(a.id, :rtp_hub)
    # no plugin configured -> no plugin port
    refute Cairn.Registry.whereis(a.id, :plugin)
  end

  test "a camera served by a plugin group gets no plugin port of its own" do
    a = %Camera{camera("cs_grp_#{System.unique_integer([:positive])}") | plugin: {:group, "det"}}
    :ok = CameraSupervisor.sync(config([a], 19_720))

    assert Cairn.Registry.whereis(a.id, :ffmpeg)
    assert Cairn.Registry.whereis(a.id, :rtp_hub)
    refute Cairn.Registry.whereis(a.id, :plugin)
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
