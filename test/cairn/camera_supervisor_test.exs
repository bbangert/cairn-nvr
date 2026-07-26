defmodule Cairn.CameraSupervisorTest do
  # drives the real DynamicSupervisor + Camera trees (ffmpeg spawns against
  # an instantly-failing file source; backoff keeps the noise to one spawn)
  use ExUnit.Case, async: false

  alias Cairn.CameraSupervisor
  alias Cairn.Config
  alias Cairn.Config.Camera

  setup do
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

    diff = %{added: [c.id], removed: [a.id], changed: [b.id]}
    new_config = config([%Camera{b | rtsp_url: "file:///dev/zero"}, c], 19_640)
    :ok = CameraSupervisor.apply_diff(diff, new_config)

    refute Cairn.Registry.whereis(a.id, :camera)
    assert Cairn.Registry.whereis(c.id, :camera)

    new_b = wait_new_pid(b.id, old_b)
    assert is_pid(new_b)
    assert new_b != old_b
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
