defmodule Cairn.CamerasDeleteFlowTest do
  # The delete flow end to end: the row goes inside the config server's
  # transaction, and every runtime owner drops the camera in its own process
  # when the broadcast lands. Nothing here calls a prune.
  use Cairn.DataCase, async: false

  @moduletag :capture_log

  alias Cairn.CameraControl
  alias Cairn.Cameras
  alias Cairn.Cameras.Setting
  alias Cairn.CameraStatus
  alias Cairn.Config
  alias Cairn.ConfigSource
  alias Cairn.Event
  alias Cairn.EventCheckpoint
  alias Cairn.PresenceCheckpoint

  # The owners prune against `Cairn.Config.Server.known_ids/0` — the
  # *application* server's published snapshot, which is the suite fixture
  # (`test/support/fixtures/configs/valid.yml`) and which this file's private,
  # DB-backed server does not publish into. So a surviving camera has to be
  # one that file names: `cam_a` stands in for it here, and `cam1` for the
  # camera the fleet no longer has.
  @survivor "cam_a"
  @deleted "cam1"

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

    # `Cairn.Cameras.server/0` reads this env: the writes have to reach the
    # private server, not the application's file-backed singleton.
    Application.put_env(:cairn, :config_server, server)
    on_exit(fn -> Application.delete_env(:cairn, :config_server) end)

    # The status, control and checkpoint tables are singletons the DB sandbox
    # does not roll back.
    on_exit(fn ->
      CameraStatus.set(@survivor, :unknown)
      CameraControl.set(@survivor, %{detection_enabled: true, recording_enabled: true})
      PresenceCheckpoint.delete(@survivor)
      EventCheckpoint.delete(@survivor)
    end)

    %{dir: dir, server: server}
  end

  test "delete takes the row, and the owners drop the camera on the broadcast", %{server: server} do
    assert {:ok, _diff, []} = create(@deleted)
    seed_runtime_state(@survivor)
    # No control overlay for `@deleted`: `set/2` is refused for an id the
    # published snapshot does not name, and the owners' snapshot here is the
    # application server's. The rest of its state is written straight to ETS.
    CameraStatus.set(@deleted, :running)
    put_checkpoints(@deleted)
    sync_owners()

    Config.Server.subscribe()
    assert {:ok, %{removed: [@deleted]}, []} = Cameras.delete(@deleted)
    assert_receive {:config_changed, %{removed: [@deleted]}}
    sync_owners()

    refute Cameras.get(@deleted)
    assert Enum.map(Config.Server.get(server).cameras, & &1.id) == []

    assert CameraStatus.get(@deleted).status == :unknown
    assert CameraControl.get(@deleted) == defaults()
    assert PresenceCheckpoint.get(@deleted) == nil
    assert EventCheckpoint.get(@deleted) == nil

    # The prune is against the ids the config still names, not against every
    # id: a camera that is still there keeps what it had.
    assert CameraStatus.get(@survivor).status == :running
    assert CameraControl.get(@survivor).detection_enabled == false
    assert PresenceCheckpoint.get(@survivor)
    assert EventCheckpoint.get(@survivor)
  end

  test "a control write for the deleted camera is refused by the owner" do
    assert {:ok, _diff, []} = create(@deleted)

    Config.Server.subscribe()
    assert {:ok, %{removed: [@deleted]}, []} = Cameras.delete(@deleted)
    assert_receive {:config_changed, %{removed: [@deleted]}}

    assert CameraControl.set(@deleted, %{detection_enabled: false}) ==
             {:error, :unknown_camera}

    # The refusal is about this camera, not about writes in general.
    assert CameraControl.set(@survivor, %{detection_enabled: false}).detection_enabled == false
  end

  # Nothing survives a delete to be reconciled or revived, so the id is free
  # again: no tombstone to lift, and no state left for the new camera to
  # inherit from the old one.
  test "the id can be created again and starts from defaults" do
    assert {:ok, _diff, []} = create(@deleted)

    Config.Server.subscribe()
    assert {:ok, %{removed: [@deleted]}, []} = Cameras.delete(@deleted)
    assert_receive {:config_changed, %{removed: [@deleted]}}

    assert {:ok, %{added: [@deleted]}, []} = create(@deleted)
    assert_receive {:config_changed, %{added: [@deleted]}}
    sync_owners()

    assert Cameras.get(@deleted)
    assert CameraStatus.get(@deleted).status == :unknown
    assert CameraControl.get(@deleted) == defaults()
  end

  defp create(id) do
    Cameras.create(%{"id" => id, "settings" => %{"rtsp_url" => "rtsp://h/#{id}"}})
  end

  defp defaults, do: %{detection_enabled: true, recording_enabled: true, min_score: nil}

  defp seed_runtime_state(id) do
    CameraStatus.set(id, :running)
    assert CameraControl.set(id, %{detection_enabled: false}).detection_enabled == false
    put_checkpoints(id)
    sync_owners()
  end

  defp put_checkpoints(id) do
    event = %Event{id: Ecto.UUID.generate(), camera_id: id, started_at: DateTime.utc_now()}
    PresenceCheckpoint.put(id, event, [], nil)
    EventCheckpoint.put(id, event)
  end

  # The prune runs in each owner's own process, and the reads above go to ETS
  # rather than through it; a call to each is what orders one against the
  # other.
  defp sync_owners do
    for owner <- [CameraStatus, CameraControl, PresenceCheckpoint, EventCheckpoint],
        do: :sys.get_state(owner)

    :ok
  end
end
