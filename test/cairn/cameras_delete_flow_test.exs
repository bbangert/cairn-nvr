defmodule Cairn.CamerasDeleteFlowTest do
  # The delete flow as a test list (plan P3-T4, critic gap 10): one test per
  # line, each stating the behaviour that line names. `cameras_test.exs`
  # already owns "delete prunes status, control and checkpoints" and "a
  # deleted camera's event rows and clips stay" — this file does not repeat
  # those bodies, only points at them where a line is already proven there.
  use Cairn.DataCase, async: false

  @moduletag :capture_log

  alias Cairn.CameraControl
  alias Cairn.Cameras
  alias Cairn.Cameras.Setting
  alias Cairn.Config
  alias Cairn.ConfigSource
  alias Cairn.Event
  alias Cairn.EventCheckpoint
  alias Cairn.PresenceCheckpoint

  # Copied from `Cairn.CamerasTest`'s "writes" describe block: a private,
  # DB-backed `Config.Server` with a stubbed `apply_diff` this test asserts
  # against, pointed at by `Cairn.Cameras.server/0` through app env.
  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_delete_flow_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    path = Path.join(dir, "config.yml")
    File.write!(path, "data_dir: #{dir}\n")

    Repo.insert!(
      Setting.changeset(%Setting{}, %{
        key: "yaml_import",
        value: %{"path" => path, "sha256" => String.duplicate("0", 64)}
      })
    )

    test_pid = self()

    server =
      start_supervised!(
        {Config.Server,
         path: path,
         name: nil,
         source: {ConfigSource, :load},
         apply_diff: fn diff, config -> send(test_pid, {:applied, diff, config}) end,
         apply_native: fn _config -> :ok end},
        id: :cameras_delete_flow_server
      )

    Application.put_env(:cairn, :config_server, server)
    on_exit(fn -> Application.delete_env(:cairn, :config_server) end)

    %{dir: dir, server: server}
  end

  test "remove leaves the row gone and the diff names it removed", %{server: server} do
    assert {:ok, _diff, []} =
             Cameras.create(%{"id" => "cam1", "settings" => %{"rtsp_url" => "rtsp://h/1"}})

    assert {:ok, %{removed: ["cam1"]}, []} = Cameras.delete("cam1")

    refute Cameras.get("cam1")
    assert Enum.map(Config.Server.get(server).cameras, & &1.id) == []
  end

  test "the stubbed apply_diff sees the removed diff — the seam CameraSupervisor.stop_camera runs through in production" do
    assert {:ok, _diff, []} =
             Cameras.create(%{"id" => "cam1", "settings" => %{"rtsp_url" => "rtsp://h/1"}})

    # Flush the create's own {:applied, ...} before deleting, so the assertion
    # below is unambiguously the delete's message.
    assert_receive {:applied, %{added: ["cam1"]}, _config}

    assert {:ok, %{removed: ["cam1"]}, []} = Cameras.delete("cam1")

    # `Config.Server.update/3` calls `apply_diff` synchronously before
    # returning (`server.ex` `apply_config/3`); in production this is
    # `Cairn.CameraSupervisor.apply_diff/2`, whose `removed` half calls
    # `stop_camera/1`. The stub here stands in for that call without
    # starting a camera tree.
    assert_receive {:applied, %{removed: ["cam1"]}, _config}
  end

  # The finding this closes: a tombstone installed by any post-commit hook
  # leaves a window between the delete committing and the tombstone landing —
  # `after_apply:` the widest of them, since it runs after `apply_diff`
  # (camera stop/start, seconds in production). A control request that read
  # the config, found the camera present, and then called
  # `CameraControl.set/2` could win that race and have its write pruned when
  # the hook caught up. This blocks `apply_diff` on a handshake to hold the
  # window open and proves the tombstone `delete_row/1` takes inside the
  # write closure, before the row goes, has already closed it.
  test "a control write for the deleted camera is refused while apply_diff is still blocked", %{
    dir: dir
  } do
    # The control table is a shared singleton the DB sandbox does not roll
    # back, and this test leaves "cam1" tombstoned (it never re-creates the
    # id, unlike `CamerasTest`'s round-trip test).
    on_exit(fn -> CameraControl.revive("cam1") end)

    path = Path.join(dir, "config.yml")
    test_pid = self()

    slow =
      start_supervised!(
        {Config.Server,
         path: path,
         name: nil,
         source: {ConfigSource, :load},
         apply_diff: fn _diff, _config ->
           send(test_pid, :applying)
           receive do: (:release -> :ok)
         end,
         apply_native: fn _config -> :ok end},
        id: :cameras_delete_flow_slow_server
      )

    Application.put_env(:cairn, :config_server, slow)

    create_task =
      Task.async(fn ->
        Cameras.create(%{"id" => "cam1", "settings" => %{"rtsp_url" => "rtsp://h/1"}})
      end)

    assert_receive :applying
    send(slow, :release)
    assert {:ok, %{added: ["cam1"]}, []} = Task.await(create_task)

    delete_task = Task.async(fn -> Cameras.delete("cam1") end)
    assert_receive :applying

    # Still blocked in `apply_diff` — the write committed, but the camera's
    # tree has not been told to stop yet, and this must already be refused.
    assert CameraControl.set("cam1", %{detection_enabled: false}) == {:error, :removed}

    send(slow, :release)
    assert {:ok, %{removed: ["cam1"]}, []} = Task.await(delete_task)
  end

  # presence_cleared for a present key on the aggregator's retire path is
  # already pinned by `Cairn.PresenceAggregatorTest`'s
  # "retire/1 clears, stops, and stays gone until the next batch" — that test
  # observes a `{nil, "person"}` key present, calls
  # `Cairn.PresenceAggregator.retire/1` (the function
  # `Cairn.CameraSupervisor.stop_camera/1` calls before tearing down the
  # camera tree, per `camera_supervisor.ex:127`), and asserts the
  # `:presence_cleared` broadcast. Not duplicated here.

  # CameraStatus and CameraControl reading back the empty shape after delete
  # is `Cairn.CamerasTest`'s "delete prunes status, control and checkpoints" —
  # not repeated here.

  # The prune is `Config.Server.update/3`'s `after_apply:`, run in the config
  # server before the call returns — so this asserts the server-owned path,
  # not a step `Cameras.delete/1` takes after it.
  test "PresenceCheckpoint and EventCheckpoint hold no row for the deleted id" do
    assert {:ok, _diff, []} =
             Cameras.create(%{"id" => "cam1", "settings" => %{"rtsp_url" => "rtsp://h/1"}})

    event = %Event{id: Ecto.UUID.generate(), camera_id: "cam1", started_at: DateTime.utc_now()}
    PresenceCheckpoint.put("cam1", event, [], nil)
    EventCheckpoint.put("cam1", event)

    assert {:ok, %{removed: ["cam1"]}, []} = Cameras.delete("cam1")

    assert PresenceCheckpoint.get("cam1") == nil
    assert EventCheckpoint.get("cam1") == nil
  end

  # D-P8: history outlives the row. Event rows and clip files for a deleted
  # id surviving is `Cairn.CamerasTest`'s "a deleted camera's event rows and
  # clips stay" — not repeated here.

  # `CairnWeb.Api.CameraController.index/2` builds its list from
  # `Cairn.Config.Server.get/1`'s `cameras` (`camera_controller.ex:21-29`),
  # never from `Cairn.Cameras.list/0` — so this is the fact that makes
  # "/api/cameras no longer lists it" true. The endpoint itself is not
  # started here (`DataCase`, no `ConnCase`); `camera_controller_test.exs`
  # (out of scope for this file) exercises the HTTP surface.
  test "the running config's camera list — what /api/cameras renders — no longer includes it", %{
    server: server
  } do
    assert {:ok, _diff, []} =
             Cameras.create(%{"id" => "cam1", "settings" => %{"rtsp_url" => "rtsp://h/1"}})

    assert {:ok, _diff, []} =
             Cameras.create(%{"id" => "cam2", "settings" => %{"rtsp_url" => "rtsp://h/2"}})

    assert {:ok, %{removed: ["cam1"]}, []} = Cameras.delete("cam1")

    assert Enum.map(Config.Server.get(server).cameras, & &1.id) == ["cam2"]
  end

  # `Native.Status` stops ticking a deleted id once its stream closes — this
  # is the phase-1-review tick behaviour (`status.ex:104-114`): the merge set
  # is `configured(state) ++ status.streams`, so a delete alone (out of
  # `configured/1`) is not enough while the engine's own stream stays open,
  # but a camera absent from *both* sets is cleared to `nil` on the next
  # tick. Pinned as a unit test in `test/cairn/native/status_test.exs`
  # ("a deleted id's status is not re-merged once its stream is also gone")
  # rather than here, because exercising it needs `Cairn.Native.Host`/
  # `Cairn.Native.Status`, not `Cairn.Cameras`.

  # The reconciler's orphan adoption (`reconciler.ex:109-131`) never
  # consults `config.cameras` — it globs every `*.mp4` under `config.data_dir`
  # and adopts whichever `event_id` its filename encodes is not already an
  # `Events` row, regardless of whether that filename's camera id is
  # configured, disabled, or deleted. That behaviour (unchanged here) is
  # already pinned by `Cairn.EventExtractorTest`'s "reconciliation deletes
  # rows with missing files and adopts orphans" (`event_extractor_test.exs`
  # ~line 530), which asserts `summary.adopted == 1` for a clip with no
  # matching row — the same path a clip left behind by a deleted camera's id
  # takes on the next boot.
end
