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
    assert diff == %{added: ["cam_c"], removed: ["cam_b"], changed: ["cam_a"], refreshed: []}
    assert_received {:applied, ^diff, %Config{}}

    assert [%{id: "cam_a", rtsp_url: "rtsp://h/CHANGED"}, %{id: "cam_c"}] =
             Config.Server.get(server).cameras
  end

  # The pre window is the one that restarts: the ring is sized from it at tree
  # init, so it cannot be swapped into a running camera.
  test "global pre-window change marks all cameras changed", %{
    server: server,
    path: path,
    dir: dir
  } do
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

    assert {:ok, %{changed: ["cam_a", "cam_b"], added: [], removed: [], refreshed: []}, []} =
             Config.Server.reload(server)
  end

  test "global post-window change refreshes every camera instead", %{
    server: server,
    path: path,
    dir: dir
  } do
    updated = """
    data_dir: #{Path.join(dir, "data")}
    udp:
      base_port: 18000
      range: 20
    events:
      post_window_seconds: 42
    cameras:
      - id: cam_a
        rtsp_url: rtsp://h/1
      - id: cam_b
        rtsp_url: rtsp://h/2
    """

    File.write!(path, updated)

    assert {:ok, %{changed: [], added: [], removed: [], refreshed: ["cam_a", "cam_b"]}, []} =
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

    assert {:ok, %{changed: ["cam_a", "cam_b"], added: [], removed: [], refreshed: []}, []} =
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

  describe "diff_cameras/2" do
    test "an identical camera is in neither list" do
      assert camera_diff(%{}) == %{added: [], removed: [], changed: [], refreshed: []}
    end

    test "host-side edits refresh the camera instead of restarting it" do
      for edit <- [
            %{"post_window_seconds" => 42},
            %{"max_event_seconds" => 120},
            %{"max_unseen_ms" => 5_000},
            %{"max_live_tracks" => 16},
            %{"stationary_after_ms" => 20_000},
            %{"track" => %{"person" => 0.5}},
            %{"record" => %{"person" => 0.8}},
            %{"retention" => %{"days" => 3}}
          ] do
        assert camera_diff(edit) ==
                 %{added: [], removed: [], changed: [], refreshed: ["cam_a"]},
               "expected #{inspect(edit)} to refresh, not restart"
      end
    end

    test "edits that reach a subprocess (or the ring) restart the camera" do
      for edit <- [
            %{"rtsp_url" => "rtsp://h/CHANGED"},
            %{"min_score" => 0.7},
            %{"plugin" => "./detect --model m.onnx"},
            %{"transcode" => true},
            %{"extra_ffmpeg_args" => ["-rtsp_transport", "tcp"]},
            %{"pre_window_seconds" => 8}
          ] do
        assert camera_diff(edit) ==
                 %{added: [], removed: [], changed: ["cam_a"], refreshed: []},
               "expected #{inspect(edit)} to restart"
      end
    end

    test "a camera edited both ways is restarted, not refreshed" do
      assert camera_diff(%{"rtsp_url" => "rtsp://h/2", "stationary_after_ms" => 20_000}) ==
               %{added: [], removed: [], changed: ["cam_a"], refreshed: []}
    end

    test "a global tracking edit refreshes the cameras that resolve through it" do
      assert camera_diff(%{}, %{"tracking" => %{"stationary_after_ms" => 20_000}}) ==
               %{added: [], removed: [], changed: [], refreshed: ["cam_a"]}
    end

    test "a global udp.base_port edit restarts every camera" do
      cams = [
        %{"id" => "cam_a", "rtsp_url" => "rtsp://h/1"},
        %{"id" => "cam_b", "rtsp_url" => "rtsp://h/2"}
      ]

      old = camera_config(cams, %{})
      new = camera_config(cams, %{"udp" => %{"base_port" => 19_000, "range" => 20}})

      # Neither the camera structs nor their indices moved, so this used to
      # fall into no bucket at all and leave every camera bound to its old
      # ports until a restart. The ports are compared resolved for exactly
      # this reason.
      assert Config.Server.diff_cameras(old, new) ==
               %{added: [], removed: [], changed: ["cam_a", "cam_b"], refreshed: []}
    end

    test "a global udp.range edit alone changes no camera's ports" do
      cams = [%{"id" => "cam_a", "rtsp_url" => "rtsp://h/1"}]
      old = camera_config(cams, %{})
      new = camera_config(cams, %{"udp" => %{"base_port" => 18_000, "range" => 40}})

      # the range only bounds allocation (`Cairn.Config` rejects exhaustion);
      # it is not an input to any camera's port block
      assert Config.Server.diff_cameras(old, new) ==
               %{added: [], removed: [], changed: [], refreshed: []}
    end

    test "a camera overriding the pre window is untouched when the global moves" do
      overridden = %{"id" => "cam_a", "rtsp_url" => "rtsp://h/1", "pre_window_seconds" => 3}
      old = camera_config([overridden], %{})
      new = camera_config([overridden], %{"events" => %{"pre_window_seconds" => 30}})

      # the override wins in `Config.windows/2`, so the ring this camera would
      # be built with has not moved: no restart, and nothing to refresh either
      assert Config.Server.diff_cameras(old, new) ==
               %{added: [], removed: [], changed: [], refreshed: []}
    end

    test "a camera overriding a global is untouched when that global moves" do
      overridden = %{"id" => "cam_a", "rtsp_url" => "rtsp://h/1", "post_window_seconds" => 7}
      old = camera_config([overridden], %{})
      new = camera_config([overridden], %{"events" => %{"post_window_seconds" => 42}})

      # the override wins in `Config.policy/2`, so nothing this camera resolves
      # moved at all: the classification is on resolved values, not raw globals
      assert Config.Server.diff_cameras(old, new) ==
               %{added: [], removed: [], changed: [], refreshed: []}
    end
  end

  describe "diff_plugin_groups/2" do
    test "added and removed groups" do
      old = config(%{"gone" => plugin("./gone"), "detect" => plugin("./detect")}, "detect")
      new = config(%{"fresh" => plugin("./fresh"), "detect" => plugin("./detect")}, "detect")

      assert Config.Server.diff_plugin_groups(old, new) ==
               %{added: ["fresh"], removed: ["gone"], changed: [], refreshed: []}
    end

    test "a changed command marks the group changed" do
      old = config(%{"detect" => plugin("./detect")}, "detect")
      new = config(%{"detect" => plugin("./detect --v2")}, "detect")

      assert Config.Server.diff_plugin_groups(old, new) ==
               %{added: [], removed: [], changed: ["detect"], refreshed: []}
    end

    test "a changed member set marks the group changed" do
      old = config(%{"detect" => plugin("./detect")}, "detect")
      new = config(%{"detect" => plugin("./detect")}, nil)

      assert Config.Server.diff_plugin_groups(old, new) ==
               %{added: [], removed: [], changed: ["detect"], refreshed: []}
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
               %{added: [], removed: [], changed: ["detect"], refreshed: []}
    end

    test "an edit to the profile file marks the group changed" do
      # Same group, same `command:`, same profile *name* — only the file's
      # content moved (input_size 416 -> 640). The expansion is in the
      # group's command by the time this diff runs, so the model flags a
      # running plugin was spawned with cannot go stale.
      old = profiled_config("test/support/fixtures/profiles/argv")
      new = profiled_config("test/support/fixtures/profiles/argv-edited")

      assert [%{command: old_command}] = old.plugin_groups
      assert [%{command: new_command}] = new.plugin_groups
      assert "416" in old_command
      assert "640" in new_command

      assert Config.Server.diff_plugin_groups(old, new) ==
               %{added: [], removed: [], changed: ["detect"], refreshed: []}
    end
  end

  # One group on the `full` profile, resolved from `dir`.
  defp profiled_config(dir) do
    from_map!(%{
      "data_dir" => "tmp/cfg_srv_test",
      "udp" => %{"base_port" => 18_000, "range" => 20},
      "profile_dirs" => [dir],
      "plugins" => %{"detect" => %{"command" => "./detect", "profile" => "full"}},
      "cameras" => [%{"id" => "cam_a", "rtsp_url" => "rtsp://h/1", "plugin" => "detect"}]
    })
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

  # Two configs whose only difference is what `edit` does to cam_a and what
  # `global` adds at the top level, diffed.
  defp camera_diff(edit, global \\ %{}) do
    base = %{"id" => "cam_a", "rtsp_url" => "rtsp://h/1"}

    Config.Server.diff_cameras(
      camera_config([base], %{}),
      camera_config([Map.merge(base, edit)], global)
    )
  end

  defp camera_config(cameras, global) do
    from_map!(
      Map.merge(
        %{
          "data_dir" => "tmp/cfg_srv_test",
          "udp" => %{"base_port" => 18_000, "range" => 20},
          "cameras" => cameras
        },
        global
      )
    )
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
