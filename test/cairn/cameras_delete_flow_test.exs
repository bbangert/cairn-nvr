defmodule Cairn.CamerasDeleteFlowTest do
  # The delete flow end to end: the row goes inside the config server's
  # transaction, and every runtime owner drops the camera in its own process
  # when the broadcast lands. Nothing here calls a prune. The two checkpoint
  # owners, and the recorders, trackers and extractors a delete has to end,
  # get their owners in later PRs and are not asserted here.
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

  # The owners prune against the *application* server's published snapshot and
  # only on its broadcasts (`t:Cairn.Config.Server.diff/0`); this file's
  # private, DB-backed server feeds neither. So the app snapshot is swapped to
  # stand for the fleet the owners see (`publish_fleet/1`), and the delete
  # reaches them as the tagged message the app server would have broadcast
  # (`prune_owners/0`). `cam_a` is a camera the suite fixture
  # (`test/support/fixtures/configs/valid.yml`) names, and so survives every
  # swap; `cam1` is the one being deleted.
  @survivor "cam_a"
  @deleted "cam1"

  @owners [CameraStatus, CameraControl]

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

    # The app snapshot is process-global; this suite is `async: false`, so no
    # other suite is reading it while it is swapped.
    original = :persistent_term.get(app_key(), nil)

    on_exit(fn ->
      if original,
        do: :persistent_term.put(app_key(), original),
        else: :persistent_term.erase(app_key())
    end)

    # The status and control tables are singletons the DB sandbox does not
    # roll back.
    on_exit(fn ->
      CameraStatus.set(@survivor, :unknown)
      CameraControl.set(@survivor, %{detection_enabled: true, recording_enabled: true})
      # The checkpoint tables are global singletons; the delete case below
      # seeds @deleted rows, so clear them in case an assertion fails first.
      EventCheckpoint.delete(@deleted)
      PresenceCheckpoint.delete(@deleted)
    end)

    %{dir: dir, server: server}
  end

  test "delete takes the row, and the owners drop the camera on the broadcast", %{server: server} do
    assert {:ok, _diff, []} = create(@deleted)
    publish_fleet([@deleted])
    seed_runtime_state(@survivor)
    seed_runtime_state(@deleted)

    Config.Server.subscribe()
    assert {:ok, %{removed: [@deleted]}, []} = Cameras.delete(@deleted)
    # The private server's own broadcast, tagged with it — which is exactly
    # why the owners do not act on it.
    assert_receive {:config_changed, %{removed: [@deleted], server: ^server}}

    publish_fleet([])
    prune_owners()

    refute Cameras.get(@deleted)
    assert Enum.map(Config.Server.get(server).cameras, & &1.id) == []

    assert CameraStatus.get(@deleted).status == :unknown
    assert CameraControl.get(@deleted) == defaults()

    # The prune is against the ids the config still names, not against every
    # id: a camera that is still there keeps what it had.
    assert CameraStatus.get(@survivor).status == :running
    assert CameraControl.get(@survivor).detection_enabled == false
  end

  # The two checkpoint tables have no owner until B3, so `delete/2` still
  # clears them directly. Pin that interim guarantee: without it the two lines
  # could go early and nothing here would catch it.
  test "delete clears the two checkpoint tables it still owns until B3" do
    assert {:ok, _diff, []} = create(@deleted)
    publish_fleet([@deleted])

    event = %Event{id: Ecto.UUID.generate(), camera_id: @deleted, started_at: DateTime.utc_now()}
    EventCheckpoint.put(@deleted, event)
    PresenceCheckpoint.put(@deleted, event, [{nil, "person"}], self())

    assert EventCheckpoint.get(@deleted)
    assert PresenceCheckpoint.get(@deleted)

    assert {:ok, %{removed: [@deleted]}, []} = Cameras.delete(@deleted)

    assert EventCheckpoint.get(@deleted) == nil
    assert PresenceCheckpoint.get(@deleted) == nil
  end

  test "a control write for the deleted camera is refused by the owner" do
    assert {:ok, _diff, []} = create(@deleted)
    publish_fleet([@deleted])
    assert CameraControl.set(@deleted, %{detection_enabled: false}).detection_enabled == false

    assert {:ok, %{removed: [@deleted]}, []} = Cameras.delete(@deleted)
    publish_fleet([])
    prune_owners()

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
    publish_fleet([@deleted])
    seed_runtime_state(@deleted)

    assert {:ok, %{removed: [@deleted]}, []} = Cameras.delete(@deleted)
    publish_fleet([])
    prune_owners()

    assert {:ok, %{added: [@deleted]}, []} = create(@deleted)
    publish_fleet([@deleted])

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
    settle_owners()
  end

  # The prune runs in each owner's own process, and the reads above go to ETS
  # rather than through it; a call to each is what orders one against the
  # other.
  defp settle_owners do
    for owner <- @owners, do: :sys.get_state(owner)
    :ok
  end

  # The message the application server would have broadcast for this delete,
  # sent straight at the owners: an untagged one, or one tagged with the
  # private server, is ignored by design.
  defp prune_owners do
    diff = %{
      added: [],
      removed: [@deleted],
      changed: [],
      refreshed: [],
      version: 0,
      server: Config.Server,
      # What the owners prune against: the fleet as of this diff, which
      # `publish_fleet/1` has just moved.
      known: Config.Server.known_ids()
    }

    for owner <- @owners, do: send(owner, {:config_changed, diff})
    settle_owners()
  end

  # The application fleet the owners prune against, plus `extra`: the app
  # server itself is left running on its own config, only its snapshot moves.
  defp publish_fleet(extra) do
    config = Config.Server.get()
    cameras = Enum.map(extra, &%Config.Camera{id: &1}) ++ config.cameras
    :persistent_term.put(app_key(), %{config | cameras: cameras})
    :ok
  end

  defp app_key, do: Config.Server.snapshot_key(Config.Server)
end
