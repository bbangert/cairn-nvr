defmodule Cairn.PluginGroupSupervisorTest do
  # drives the real DynamicSupervisor + group ports (the plugin command is a
  # long sleep, so nothing but the Port machinery is exercised)
  use ExUnit.Case, async: false

  alias Cairn.Config
  alias Cairn.Config.Camera
  alias Cairn.Config.PluginGroup
  alias Cairn.PluginGroupSupervisor

  @data_dir "tmp/plugin_group_sup_test"

  setup do
    File.mkdir_p!(Path.join(@data_dir, "log"))
    # Registered first so LIFO runs it last, after the groups are stopped
    on_exit(fn -> File.rm_rf!(@data_dir) end)
    Application.put_env(:cairn, :start_cameras, true)
    on_exit(fn -> Application.put_env(:cairn, :start_cameras, false) end)

    on_exit(fn ->
      Enum.each(Cairn.Registry.ids_for_role(:plugin_group), &PluginGroupSupervisor.stop_group/1)
    end)

    :ok
  end

  defp camera(id), do: %Camera{id: id, rtsp_url: "rtsp://h/#{id}", plugin: {:group, id}}

  defp group(name, members, command \\ ["sh", "-c", "sleep 30"]) do
    %PluginGroup{
      name: name,
      command: command,
      members: Enum.map(members, &%{id: &1, udp_port: 19_300, min_score: %{"default" => 0.5}})
    }
  end

  defp config(groups, cameras) do
    %Config{
      data_dir: @data_dir,
      udp_base_port: 19_300,
      udp_port_range: 20,
      cameras: cameras,
      plugin_groups: groups
    }
  end

  test "sync starts groups with members, skips empty ones, and is idempotent" do
    a = "gs_a_#{System.unique_integer([:positive])}"
    empty = "gs_empty_#{System.unique_integer([:positive])}"
    cam = camera("cam_#{a}")

    :ok = PluginGroupSupervisor.sync(config([group(a, [cam.id]), group(empty, [])], [cam]))

    pid = Cairn.Registry.whereis(a, :plugin_group)
    assert is_pid(pid)
    refute Cairn.Registry.whereis(empty, :plugin_group)

    :ok = PluginGroupSupervisor.sync(config([group(a, [cam.id]), group(empty, [])], [cam]))
    assert Cairn.Registry.whereis(a, :plugin_group) == pid
  end

  test "sync stops groups that are no longer wanted" do
    a = "gs_gone_#{System.unique_integer([:positive])}"
    b = "gs_keep_#{System.unique_integer([:positive])}"
    cams = [camera("cam_#{a}"), camera("cam_#{b}")]
    [cam_a, cam_b] = cams

    groups = [group(a, [cam_a.id]), group(b, [cam_b.id])]
    :ok = PluginGroupSupervisor.sync(config(groups, cams))
    assert Cairn.Registry.whereis(a, :plugin_group)

    # a's last member left: no members, nothing to serve
    :ok = PluginGroupSupervisor.sync(config([group(a, []), group(b, [cam_b.id])], cams))
    refute Cairn.Registry.whereis(a, :plugin_group)
    assert Cairn.Registry.whereis(b, :plugin_group)
  end

  test "apply_diff restarts changed groups and leaves untouched ones alone" do
    a = "gs_chg_#{System.unique_integer([:positive])}"
    b = "gs_same_#{System.unique_integer([:positive])}"
    c = "gs_new_#{System.unique_integer([:positive])}"
    cams = Enum.map([a, b, c], &camera("cam_#{&1}"))
    [cam_a, cam_b, cam_c] = cams

    started = [group(a, [cam_a.id]), group(b, [cam_b.id])]
    :ok = PluginGroupSupervisor.sync(config(started, cams))

    old_a = Cairn.Registry.whereis(a, :plugin_group)
    old_b = Cairn.Registry.whereis(b, :plugin_group)

    # a gains a member, b is untouched, c is new
    new_config =
      config(
        [group(a, [cam_a.id, cam_c.id]), group(b, [cam_b.id]), group(c, [cam_c.id])],
        cams
      )

    :ok =
      PluginGroupSupervisor.apply_diff(%{added: [c], removed: [], changed: [a]}, new_config)

    new_a = wait_new_pid(a, old_a)
    assert is_pid(new_a)
    assert new_a != old_a
    assert Cairn.Registry.whereis(b, :plugin_group) == old_b
    assert Cairn.Registry.whereis(c, :plugin_group)
  end

  test "sync refreshes a surviving group with the new config" do
    a = "gs_refresh_#{System.unique_integer([:positive])}"
    cam = camera("cam_#{a}")

    :ok = PluginGroupSupervisor.sync(config([group(a, [cam.id])], [cam]))
    pid = Cairn.Registry.whereis(a, :plugin_group)
    assert {%Camera{}, %{post: 10}} = :sys.get_state(pid).routes[cam.id]

    # only the camera's window moved, so the group itself is unchanged and
    # keeps running — its routes still have to follow the new config
    widened = %Camera{cam | post_window_seconds: 42}
    :ok = PluginGroupSupervisor.sync(config([group(a, [cam.id])], [widened]))

    assert Cairn.Registry.whereis(a, :plugin_group) == pid
    assert {%Camera{post_window_seconds: 42}, %{post: 42}} = :sys.get_state(pid).routes[cam.id]
  end

  test "apply_diff stops removed groups" do
    a = "gs_rm_#{System.unique_integer([:positive])}"
    cam = camera("cam_#{a}")

    :ok = PluginGroupSupervisor.sync(config([group(a, [cam.id])], [cam]))
    assert Cairn.Registry.whereis(a, :plugin_group)

    :ok =
      PluginGroupSupervisor.apply_diff(%{added: [], removed: [a], changed: []}, config([], []))

    refute Cairn.Registry.whereis(a, :plugin_group)
  end

  test "sync is a no-op when child starting is disabled" do
    Application.put_env(:cairn, :start_cameras, false)
    a = "gs_off_#{System.unique_integer([:positive])}"
    cam = camera("cam_#{a}")

    :ok = PluginGroupSupervisor.sync(config([group(a, [cam.id])], [cam]))
    refute Cairn.Registry.whereis(a, :plugin_group)
  end

  test "stop_group on an unknown name is a no-op" do
    assert :ok = PluginGroupSupervisor.stop_group("never_started")
  end

  # Flunks rather than returning nil: a "restarted" assertion that compares
  # against the old pid passes trivially on nil.
  defp wait_new_pid(name, old, attempts \\ 100) do
    case Cairn.Registry.whereis(name, :plugin_group) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_new_pid(name, old, attempts - 1)

      _ ->
        flunk("plugin group #{name} never came back with a new pid (was #{inspect(old)})")
    end
  end
end
