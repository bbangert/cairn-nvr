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

    server =
      start_supervised!(
        {Config.Server, path: path, name: nil, apply_diff: apply_diff},
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

  test "invalid reload keeps old config and reports errors", %{server: server, path: path} do
    old = Config.Server.get(server)
    File.write!(path, "cameras: [{id: cam_a}]\n")

    assert {:error, errors} = Config.Server.reload(server)
    assert Enum.any?(errors, &(&1 =~ "rtsp_url is required"))
    refute_received {:applied, _, _}
    assert Config.Server.get(server) == old
    assert %{errors: [_ | _]} = Config.Server.last_load(server)
  end
end
