defmodule Cairn.Config.ServerUpdateTest do
  use Cairn.DataCase, async: false

  @moduletag :capture_log

  alias Cairn.Cameras
  alias Cairn.Cameras.Camera
  alias Cairn.Cameras.Setting
  alias Cairn.Config
  alias Cairn.ConfigSource

  @stub_onnx "test/support/fixtures/models/stub.onnx"
  @stub_names "test/support/fixtures/models/stub.names"

  # Two profiles that resolve to different models, so any two cameras split
  # across them fail the one-model-per-VM rule.
  @argv_dir "test/support/fixtures/profiles/argv"

  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_upd_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    path =
      write_yaml!(dir, """
      data_dir: #{dir}
      profile_dirs:
        - #{@argv_dir}
      plugins:
        full:
          profile: full
        partial:
          profile: partial
      """)

    mark_imported!(path)
    server = private_server(path, :config_update_server)
    point_cameras_at(server)

    %{dir: dir, path: path, server: server}
  end

  # The two saves serialize on the server's mailbox, not on the transaction:
  # `mode: :immediate` is what keeps a writer that is *not* the server out of
  # the render, and this test does not exercise that.
  test "two saves racing the cross-camera rules serialize, and one is rejected", %{server: server} do
    saves = [
      fn -> Config.Server.update(server, insert_fun("cam_full", "full")) end,
      fn -> Config.Server.update(server, insert_fun("cam_partial", "partial")) end
    ]

    results = saves |> Enum.map(&Task.async/1) |> Task.await_many(30_000)

    assert Enum.count(results, &match?({:ok, _diff, _warnings}, &1)) == 1
    assert [{:error, errors}] = Enum.reject(results, &match?({:ok, _diff, _warnings}, &1))
    assert Enum.any?(errors, &(&1 =~ "different models (full, partial)"))

    # The loser's row is gone, not merely unread.
    assert Repo.aggregate(Camera, :count) == 1
  end

  # Under the sandbox the transaction is a savepoint, so this is the
  # executable form of the spike’s §4.3 reading: a rolled-back row is absent,
  # not merely unread.
  test "a rejected save rolls the row back", %{server: server} do
    assert {:error, [msg]} = create("cam_x", "full", %{"min_score" => 2})
    assert msg =~ "camera cam_x: min_score values must be 0..1"
    assert Repo.get(Camera, "cam_x") == nil
    # a form error, not config health
    assert Config.Server.last_load(server).errors == []
  end

  test "a fleet-level rejection rolls the row back", %{server: server} do
    assert {:ok, _diff, _warnings} = Config.Server.update(server, insert_fun("cam_a", "full"))

    assert {:error, errors} = Config.Server.update(server, insert_fun("cam_x", "partial"))
    assert Enum.any?(errors, &(&1 =~ "different models (full, partial)"))
    assert Repo.get(Camera, "cam_x") == nil
  end

  # The source skips a faulty row so one drifted camera cannot take the fleet
  # down; `reject_skipped:` narrows that to the row the save is about, and
  # only that row.
  test "another camera's skip does not reject a save", %{path: path} do
    insert_camera!("cam_bad", 0, %{"rtsp_url" => "rtsp://h/bad", "min_score" => 2})
    server = path |> private_server(:config_update_other_skip_server) |> point_cameras_at()
    assert Map.has_key?(Config.Server.last_load(server).skipped, "cam_bad")

    assert {:ok, %{added: ["cam_a"]}, warnings} = create("cam_a", "full")
    assert Enum.any?(warnings, &(&1 =~ "camera cam_bad: skipped — "))

    # …and with no `reject_skipped:` at all, a save that skips its own row
    # still succeeds: the default is the load's degradation, unchanged.
    assert {:ok, _diff, own} =
             Config.Server.update(server, insert_fun("cam_y", "full", %{"min_score" => 2}))

    assert Enum.any?(own, &(&1 =~ "camera cam_y: skipped — "))
    assert Repo.get(Camera, "cam_y")
  end

  test "a rejected save leaves last_load and the active config untouched", %{server: server} do
    assert {:ok, _diff, _warnings} = create("cam_a", "full")

    config = Config.Server.get(server)
    last_load = Config.Server.last_load(server)

    assert {:error, _errors} = create("cam_x", "full", %{"min_score" => 2})

    assert Config.Server.get(server) == config
    assert Config.Server.last_load(server) == last_load
  end

  # The reload ordering, on the save path: detection is the in-VM engine, so
  # the model a restarted camera opens a stream on must already be the new one.
  test "an accepted save applies engine-first like reload", %{server: server} do
    assert {:ok, _diff, _warnings} = Config.Server.update(server, insert_fun("cam_a", "full"))

    # oldest message first: the engine, then the cameras
    assert_receive {:native_applied, %Config{cameras: [%{id: "cam_a"}]}}
    assert_received {:applied, %{added: ["cam_a"]}, %Config{}}
  end

  test "an accepted save and a reload both broadcast on the config topic", %{server: server} do
    Config.Server.subscribe()

    assert {:ok, _diff, _warnings} = Config.Server.update(server, insert_fun("cam_a", "full"))
    assert_receive {:config_changed, %{added: ["cam_a"]}}

    assert {:ok, _diff, _warnings} = Config.Server.reload(server)
    assert_receive {:config_changed, %{added: [], changed: [], refreshed: [], removed: []}}
  end

  test "the snapshot is published before apply_diff", %{path: path} do
    name = :update_snapshot_server
    test_pid = self()
    on_exit(fn -> :persistent_term.erase(Config.Server.snapshot_key(name)) end)

    server =
      start_supervised!(
        {Config.Server,
         path: path,
         name: name,
         source: {ConfigSource, :load},
         apply_diff: fn _diff, _config ->
           send(test_pid, {:seen, Config.Server.snapshot_camera("cam_a", name)})
         end,
         apply_native: fn _config -> :ok end},
        id: :config_update_snapshot_server
      )

    assert {:ok, _diff, _warnings} = Config.Server.update(server, insert_fun("cam_a", "full"))
    assert_received {:seen, {:ok, %{id: "cam_a"}, %Config{}}}
  end

  test "update on a file-backed source is refused", %{path: path} do
    server =
      start_supervised!({Config.Server, path: path, name: nil}, id: :config_update_file_server)

    assert {:error, [msg]} = Config.Server.update(server, insert_fun("cam_a", "full"))
    assert msg =~ "needs a DB-backed"
    refute_received {:applied, _diff, _config}
  end

  test "a write error is reported as such", %{server: server} do
    assert Config.Server.update(server, fn -> {:error, :boom} end) == {:error, {:write, :boom}}
    refute_received {:applied, _diff, _config}
    refute_received {:native_applied, _config}
  end

  test "a write closure with a wrong-shaped return is reported as a write error", %{
    server: server
  } do
    config = Config.Server.get(server)

    assert Config.Server.update(server, fn -> {:ok, :row} end) ==
             {:error, {:write, {:bad_return, {:ok, :row}}}}

    assert Config.Server.get(server) == config
    refute_received {:applied, _diff, _config}
    refute_received {:native_applied, _config}
  end

  test "a write closure that raises is reported as a write error", %{server: server} do
    config = Config.Server.get(server)

    assert Config.Server.update(server, fn -> raise "boom" end) ==
             {:error, {:write, %RuntimeError{message: "boom"}}}

    assert Config.Server.get(server) == config
    refute_received {:applied, _diff, _config}
    refute_received {:native_applied, _config}
  end

  test "disabling a camera is validated like any other save", %{dir: dir} do
    # Four detecting cameras put the ladder at 4 fps, where the solo profile
    # is pinned; disabling one raises the ladder to 7 and the two disagree.
    profiles =
      ladder_dir!(dir, """
      model:
        onnx: #{@stub_onnx}
      model_profile: yolox
      input_size: 640
      labels: #{@stub_names}
      sample_fps: 4
      """)

    path =
      write_yaml!(dir, """
      data_dir: #{dir}
      profile_dirs:
        - #{profiles}
      plugins:
        det:
          profile: ladder
        solo:
          profile: solo
      """)

    insert_camera!("cam_a", 0, %{"rtsp_url" => "rtsp://h/1", "plugin" => "det"})
    insert_camera!("cam_b", 1, %{"rtsp_url" => "rtsp://h/2", "plugin" => "det"})
    insert_camera!("cam_c", 2, %{"rtsp_url" => "rtsp://h/3", "plugin" => "det"})
    insert_camera!("cam_d", 3, %{"rtsp_url" => "rtsp://h/4", "plugin" => "solo"})

    server = path |> private_server(:config_update_ladder_server) |> point_cameras_at()
    assert length(Config.Server.get(server).cameras) == 4

    assert {:error, errors} = Cameras.set_enabled("cam_c", false)
    assert Enum.any?(errors, &(&1 =~ "different models (ladder, solo)"))
    assert Repo.get(Camera, "cam_c").enabled
  end

  test "a failed boot leaves the rows readable and the next clean save brings the fleet up",
       %{dir: dir, path: path} do
    insert_camera!("cam_full", 0, %{"rtsp_url" => "rtsp://h/1", "plugin" => "full"})
    insert_camera!("cam_partial", 1, %{"rtsp_url" => "rtsp://h/2", "plugin" => "partial"})

    server = private_server(path, :config_update_failed_boot_server)
    point_cameras_at(server)

    assert Config.Server.get(server).cameras == []
    assert Config.Server.get(server).data_dir == dir
    assert Config.Server.last_load(server).errors != []
    assert length(Cameras.list()) == 2

    assert {:ok, %{added: ["cam_full"]}, _warnings} = Cameras.delete("cam_partial")
    assert [%{id: "cam_full"}] = Config.Server.get(server).cameras
  end

  # The post-commit half of a write belongs to the commit: the server applies
  # and announces whatever becomes of the caller, so a prune left on the
  # caller's side of a 30 s call is a prune that can simply not happen.
  test "after_apply runs on the server with the applied diff", %{server: server} do
    test_pid = self()

    assert {:ok, diff, _warnings} =
             Config.Server.update(server, insert_fun("cam_a", "full"),
               after_apply: fn applied -> send(test_pid, {:after_apply, applied, self()}) end
             )

    assert_received {:after_apply, ^diff, callback_pid}
    assert callback_pid == server
  end

  # The write is committed by the time the callback runs — which is what lets
  # a prune read the rows that are left rather than be told them.
  test "after_apply sees the committed rows", %{server: server} do
    test_pid = self()

    assert {:ok, _diff, _warnings} =
             Config.Server.update(server, insert_fun("cam_a", "full"),
               after_apply: fn _diff ->
                 send(test_pid, {:seen, Enum.map(Cameras.list(), & &1.id)})
               end
             )

    assert_received {:seen, ["cam_a"]}
  end

  test "after_apply does not run on a rejected write", %{server: server} do
    test_pid = self()
    callback = fn _diff -> send(test_pid, :after_apply) end

    assert {:ok, _diff, _warnings} = Config.Server.update(server, insert_fun("cam_a", "full"))

    assert {:error, errors} =
             Config.Server.update(server, insert_fun("cam_x", "partial"), after_apply: callback)

    assert Enum.any?(errors, &(&1 =~ "different models (full, partial)"))

    assert Config.Server.update(server, fn -> {:error, :boom} end, after_apply: callback) ==
             {:error, {:write, :boom}}

    refute_received :after_apply
  end

  test "a callback that raises is logged and leaves the save applied", %{server: server} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{added: ["cam_a"]}, _warnings} =
                 Config.Server.update(server, insert_fun("cam_a", "full"),
                   after_apply: fn _diff -> raise "rtsp://user:hunter2@host" end
                 )
      end)

    # the module only: an exception message can carry the changeset that
    # failed, credentials included.
    assert log =~ "after_apply raised: RuntimeError"
    refute log =~ "hunter2"
    assert [%{id: "cam_a"}] = Config.Server.get(server).cameras
  end

  test "a callback that exits logs the reason's shape only", %{server: server} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{added: ["cam_a"]}, _warnings} =
                 Config.Server.update(server, insert_fun("cam_a", "full"),
                   after_apply: fn _diff -> exit({:shutdown, "rtsp://user:hunter2@host"}) end
                 )
      end)

    assert log =~ "after_apply exit: non-atom exit"
    refute log =~ "hunter2"
    # `alive?` only proves the process wasn't reaped; a synchronous call proves
    # the server is actually answering after the callback's exit.
    assert %{cameras: [%{id: "cam_a"}]} = Config.Server.get(server)
  end

  # The ordering that matters: a subscriber reacting to the broadcast by
  # calling `get/1` shares this mailbox with the callback, so a slow prune
  # run after the broadcast would make that read queue behind it.
  test "after_apply runs before the config-changed broadcast", %{server: server} do
    test_pid = self()
    Config.Server.subscribe()

    assert {:ok, _diff, _warnings} =
             Config.Server.update(server, insert_fun("cam_a", "full"),
               after_apply: fn _diff -> send(test_pid, :callback_ran) end
             )

    # Order, not just presence: `assert_receive`/`assert_received` match
    # anywhere in the mailbox, so a reversed arrival would pass either
    # ordering just the same. The mailbox also carries `private_server/2`'s
    # own `:native_applied`/`:applied` messages, so the two of interest are
    # picked out of a full drain rather than assumed to be the only ones.
    mailbox = flush_mailbox()
    callback_at = Enum.find_index(mailbox, &(&1 == :callback_ran))
    broadcast_at = Enum.find_index(mailbox, &match?({:config_changed, %{added: ["cam_a"]}}, &1))

    assert callback_at, "expected :callback_ran in #{inspect(mailbox)}"
    assert broadcast_at, "expected {:config_changed, _} in #{inspect(mailbox)}"
    assert callback_at < broadcast_at
  end

  test "a callback that is not a 1-arity fun is refused before the write", %{server: server} do
    assert_raise ArgumentError, ~r/after_apply/, fn ->
      Config.Server.update(server, insert_fun("cam_a", "full"), after_apply: :nope)
    end

    assert Repo.get(Camera, "cam_a") == nil
  end

  # The reason `after_commit:` exists at all: a tombstone installed only in
  # `after_apply:` would still be racing the seconds-long `apply_diff` this
  # stubbed one stands in for, so this proves it runs on the near side of it.
  test "after_commit runs before apply_diff", %{server: server} do
    test_pid = self()

    assert {:ok, _diff, _warnings} =
             Config.Server.update(server, insert_fun("cam_a", "full"),
               after_commit: fn -> send(test_pid, :committed) end
             )

    mailbox = flush_mailbox()
    committed_at = Enum.find_index(mailbox, &(&1 == :committed))
    applied_at = Enum.find_index(mailbox, &match?({:applied, %{added: ["cam_a"]}, _config}, &1))

    assert committed_at, "expected :committed in #{inspect(mailbox)}"
    assert applied_at, "expected {:applied, _, _} in #{inspect(mailbox)}"
    assert committed_at < applied_at
  end

  test "after_commit does not run on a rejected write", %{server: server} do
    test_pid = self()
    callback = fn -> send(test_pid, :after_commit) end

    assert {:ok, _diff, _warnings} = Config.Server.update(server, insert_fun("cam_a", "full"))

    assert {:error, errors} =
             Config.Server.update(server, insert_fun("cam_x", "partial"), after_commit: callback)

    assert Enum.any?(errors, &(&1 =~ "different models (full, partial)"))

    assert Config.Server.update(server, fn -> {:error, :boom} end, after_commit: callback) ==
             {:error, {:write, :boom}}

    refute_received :after_commit
  end

  test "a callback that is not a 0-arity fun is refused before the write", %{server: server} do
    assert_raise ArgumentError, ~r/after_commit/, fn ->
      Config.Server.update(server, insert_fun("cam_a", "full"), after_commit: :nope)
    end

    assert Repo.get(Camera, "cam_a") == nil
  end

  defp flush_mailbox do
    receive do
      msg -> [msg | flush_mailbox()]
    after
      0 -> []
    end
  end

  defp private_server(path, id) do
    test_pid = self()

    start_supervised!(
      {Config.Server,
       path: path,
       name: nil,
       source: {ConfigSource, :load},
       apply_diff: fn diff, config -> send(test_pid, {:applied, diff, config}) end,
       apply_native: fn config -> send(test_pid, {:native_applied, config}) end},
      id: id
    )
  end

  # `Cairn.Cameras.server/0` reads this env, so the context's writes reach the
  # private server rather than the application's file-backed singleton.
  defp point_cameras_at(server) do
    Application.put_env(:cairn, :config_server, server)
    on_exit(fn -> Application.delete_env(:cairn, :config_server) end)
    server
  end

  # Through the context, so the save carries `reject_skipped: id`.
  defp create(id, plugin, extra \\ %{}) do
    settings = Map.merge(%{"rtsp_url" => "rtsp://h/#{id}", "plugin" => plugin}, extra)
    Cameras.create(%{"id" => id, "settings" => settings})
  end

  defp insert_fun(id, plugin, extra \\ %{}) do
    settings = Map.merge(%{"rtsp_url" => "rtsp://h/#{id}", "plugin" => plugin}, extra)

    fn ->
      changeset = Camera.changeset(%Camera{}, %{id: id, position: 0, settings: settings})
      with {:ok, _row} <- Repo.insert(changeset), do: :ok
    end
  end

  defp insert_camera!(id, position, settings) do
    Repo.insert!(Camera.changeset(%Camera{}, %{id: id, position: position, settings: settings}))
  end

  defp write_yaml!(dir, body) do
    path = Path.join(dir, "config.yml")
    File.write!(path, body)
    path
  end

  # A marker with a sha nothing matches: every YAML here omits `cameras:`, so
  # drift never reads it — it is here to keep the importer out of the way.
  defp mark_imported!(path) do
    Repo.insert!(
      Setting.changeset(%Setting{}, %{
        key: "yaml_import",
        value: %{
          "path" => path,
          "sha256" => String.duplicate("0", 64),
          "imported_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      })
    )
  end

  # `config_source_test.exs`'s two-rung tier-1 ladder: on tier 1 (floor 2 fps,
  # cap 10) the fleet size alone moves the derived rate — 2 cameras derive 10,
  # 3 derive 7, 4 derive 4.
  defp ladder_dir!(dir, solo_yaml) do
    profiles = Path.join(dir, "profiles")
    File.mkdir_p!(profiles)

    File.write!(Path.join(profiles, "ladder.yml"), """
    tier: 1
    model_profile: yolox
    labels: #{@stub_names}
    model_ladder:
      - model:
          onnx: #{@stub_onnx}
        input_size: 640
        engine_budget: 17
      - model:
          onnx: #{@stub_onnx}
        input_size: 416
        engine_budget: 75
    supported_cameras: 40
    """)

    File.write!(Path.join(profiles, "solo.yml"), solo_yaml)
    profiles
  end
end
