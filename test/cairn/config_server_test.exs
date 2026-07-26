defmodule Cairn.Config.ServerTest do
  use ExUnit.Case, async: true

  alias Cairn.Config

  @base """
  data_dir: <%= data_dir %>
  udp:
    base_port: 18000
    range: 20
  cameras:
    - id: cam_a
      rtsp_url: rtsp://h/1
    - id: cam_b
      rtsp_url: rtsp://h/2
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_srv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    path = Path.join(dir, "config.yml")
    File.write!(path, EEx.eval_string(@base, data_dir: Path.join(dir, "data")))

    test_pid = self()
    apply_diff = fn diff, config -> send(test_pid, {:applied, diff, config}) end
    apply_group_diff = fn diff, config -> send(test_pid, {:groups_applied, diff, config}) end

    server =
      start_supervised!(
        {Config.Server,
         path: path, name: nil, apply_diff: apply_diff, apply_group_diff: apply_group_diff},
        id: :config_server_under_test
      )

    %{dir: dir, path: path, server: server}
  end

  test "loads config and ensures data dirs", %{server: server, dir: dir} do
    config = Config.Server.get(server)
    assert [%{id: "cam_a"}, %{id: "cam_b"}] = config.cameras
    assert File.dir?(Path.join([dir, "data", "events"]))
    assert File.dir?(Path.join([dir, "data", "log"]))
  end

  test "reload diffs added/removed/changed cameras", %{server: server, path: path, dir: dir} do
    updated = """
    data_dir: #{Path.join(dir, "data")}
    udp:
      base_port: 18000
      range: 20
    cameras:
      - id: cam_a
        rtsp_url: rtsp://h/CHANGED
      - id: cam_c
        rtsp_url: rtsp://h/3
    """

    File.write!(path, updated)

    assert {:ok, diff, []} = Config.Server.reload(server)
    assert diff == %{added: ["cam_c"], removed: ["cam_b"], changed: ["cam_a"]}
    assert_received {:applied, ^diff, %Config{}}

    assert [%{id: "cam_a", rtsp_url: "rtsp://h/CHANGED"}, %{id: "cam_c"}] =
             Config.Server.get(server).cameras
  end

  test "global window change marks all cameras changed", %{server: server, path: path, dir: dir} do
    updated = """
    data_dir: #{Path.join(dir, "data")}
    udp:
      base_port: 18000
      range: 20
    events:
      pre_window_seconds: 8
    cameras:
      - id: cam_a
        rtsp_url: rtsp://h/1
      - id: cam_b
        rtsp_url: rtsp://h/2
    """

    File.write!(path, updated)

    assert {:ok, %{changed: ["cam_a", "cam_b"], added: [], removed: []}, []} =
             Config.Server.reload(server)
  end

  test "reordering cameras marks both as changed (their udp ports shift)", %{
    server: server,
    path: path,
    dir: dir
  } do
    updated = """
    data_dir: #{Path.join(dir, "data")}
    udp:
      base_port: 18000
      range: 20
    cameras:
      - id: cam_b
        rtsp_url: rtsp://h/2
      - id: cam_a
        rtsp_url: rtsp://h/1
    """

    File.write!(path, updated)

    assert {:ok, %{changed: ["cam_a", "cam_b"], added: [], removed: []}, []} =
             Config.Server.reload(server)
  end

  test "reload applies the plugin group diff before the camera diff", %{
    server: server,
    path: path,
    dir: dir
  } do
    updated = """
    data_dir: #{Path.join(dir, "data")}
    udp:
      base_port: 18000
      range: 20
    plugins:
      detect:
        command: ./detect --model m.onnx
    cameras:
      - id: cam_a
        rtsp_url: rtsp://h/1
        plugin: detect
      - id: cam_b
        rtsp_url: rtsp://h/2
    """

    File.write!(path, updated)

    assert {:ok, %{changed: ["cam_a"]}, []} = Config.Server.reload(server)

    # oldest message first: groups are applied before cameras
    assert_received first
    assert {:groups_applied, %{added: ["detect"], removed: [], changed: []}, %Config{}} = first

    assert_received second
    assert {:applied, %{changed: ["cam_a"]}, %Config{}} = second
  end

  test "reload applies an empty group diff when no group changed", %{
    server: server,
    path: path,
    dir: dir
  } do
    updated = """
    data_dir: #{Path.join(dir, "data")}
    udp:
      base_port: 18000
      range: 20
    cameras:
      - id: cam_a
        rtsp_url: rtsp://h/CHANGED
      - id: cam_b
        rtsp_url: rtsp://h/2
    """

    File.write!(path, updated)

    assert {:ok, %{changed: ["cam_a"]}, []} = Config.Server.reload(server)
    assert_received {:applied, _, _}
    assert_received {:groups_applied, %{added: [], removed: [], changed: []}, %Config{}}
  end

  describe "diff_plugin_groups/2" do
    test "added and removed groups" do
      old = config(%{"gone" => plugin("./gone"), "detect" => plugin("./detect")}, "detect")
      new = config(%{"fresh" => plugin("./fresh"), "detect" => plugin("./detect")}, "detect")

      assert Config.Server.diff_plugin_groups(old, new) ==
               %{added: ["fresh"], removed: ["gone"], changed: []}
    end

    test "a changed command marks the group changed" do
      old = config(%{"detect" => plugin("./detect")}, "detect")
      new = config(%{"detect" => plugin("./detect --v2")}, "detect")

      assert Config.Server.diff_plugin_groups(old, new) ==
               %{added: [], removed: [], changed: ["detect"]}
    end

    test "a changed member set marks the group changed" do
      old = config(%{"detect" => plugin("./detect")}, "detect")
      new = config(%{"detect" => plugin("./detect")}, nil)

      assert Config.Server.diff_plugin_groups(old, new) ==
               %{added: [], removed: [], changed: ["detect"]}
    end

    test "a member's port shift marks the group changed" do
      old = config(%{"detect" => plugin("./detect")}, "detect")

      new =
        %{
          "data_dir" => "tmp/cfg_srv_test",
          "udp" => %{"base_port" => 18_000, "range" => 20},
          "plugins" => %{"detect" => plugin("./detect")},
          "cameras" => [
            %{"id" => "cam_b", "rtsp_url" => "rtsp://h/2"},
            %{"id" => "cam_a", "rtsp_url" => "rtsp://h/1", "plugin" => "detect"}
          ]
        }
        |> from_map!()

      assert [%{members: [%{id: "cam_a", udp_port: 18_000}]}] = old.plugin_groups
      assert [%{members: [%{id: "cam_a", udp_port: 18_004}]}] = new.plugin_groups

      assert Config.Server.diff_plugin_groups(old, new) ==
               %{added: [], removed: [], changed: ["detect"]}
    end
  end

  test "invalid reload keeps old config and reports errors", %{server: server, path: path} do
    old = Config.Server.get(server)
    File.write!(path, "cameras: [{id: cam_a}]\n")

    assert {:error, errors} = Config.Server.reload(server)
    assert Enum.any?(errors, &(&1 =~ "rtsp_url is required"))
    refute_received {:applied, _, _}
    assert Config.Server.get(server) == old
    assert %{errors: [_ | _]} = Config.Server.last_load(server)
  end

  defp plugin(command), do: %{"command" => command}

  defp config(plugins, cam_a_plugin) do
    cam_a = %{"id" => "cam_a", "rtsp_url" => "rtsp://h/1"}
    cam_a = if cam_a_plugin, do: Map.put(cam_a, "plugin", cam_a_plugin), else: cam_a

    from_map!(%{
      "data_dir" => "tmp/cfg_srv_test",
      "udp" => %{"base_port" => 18_000, "range" => 20},
      "plugins" => plugins,
      "cameras" => [cam_a, %{"id" => "cam_b", "rtsp_url" => "rtsp://h/2"}]
    })
  end

  defp from_map!(map) do
    {:ok, config, _warnings} = Config.from_map(map)
    config
  end
end
