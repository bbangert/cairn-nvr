defmodule Cairn.CameraStatusTest do
  # Uses the globally-supervised Cairn.CameraStatus with unique camera ids.
  # NOT async: the prune tests empty the shared table of every id the test
  # env's config does not name.
  use ExUnit.Case, async: false

  alias Cairn.CameraStatus

  setup do
    id = "st_#{System.unique_integer([:positive])}"
    on_exit(fn -> prune_now() end)
    %{id: id}
  end

  test "unknown cameras read as :unknown", %{id: id} do
    assert CameraStatus.get(id) == %{status: :unknown, probe: nil, plugin_status: nil}
  end

  test "plugin status is merged and broadcast like any other field", %{id: id} do
    CameraStatus.subscribe()

    CameraStatus.put(id, %{status: :running})
    assert_receive {:camera_status, ^id, %{status: :running}}

    CameraStatus.put(id, %{plugin_status: %{"state" => "ready", "detail" => "model loaded"}})
    assert_receive {:camera_status, ^id, info}
    assert info.status == :running
    assert info.plugin_status == %{"state" => "ready", "detail" => "model loaded"}
  end

  test "writes accumulate and broadcast", %{id: id} do
    CameraStatus.subscribe()

    CameraStatus.put(id, %{status: :running})
    assert_receive {:camera_status, ^id, %{status: :running}}

    CameraStatus.put(id, %{probe: %{codec: "h264", fps: 20.0}})
    assert_receive {:camera_status, ^id, info}
    assert info.status == :running
    assert info.probe.codec == "h264"

    assert CameraStatus.get(id) == info
    assert CameraStatus.all()[id] == info
  end

  # The owner prunes its own table in its own callback: nobody hands it a list
  # of ids, it asks the published snapshot which cameras exist.
  test "a config change drops the cameras the snapshot no longer names", %{id: id} do
    CameraStatus.put(id, %{status: :running})
    CameraStatus.set("cam_a", :running)

    prune_now()

    assert CameraStatus.all()[id] == nil
    assert CameraStatus.all()["cam_a"]
  end

  # The delete's membership is frozen on the delete's diff, so the create that
  # overtook it in the snapshot cannot save the old row: pruning against the
  # moving snapshot here would leave the new camera wearing the old status.
  test "a delete handled after the same id was re-created still drops the row", %{id: id} do
    CameraStatus.put(id, %{status: :running})

    with_snapshot_naming(id, fn ->
      send(CameraStatus, {:config_changed, %{diff() | known: without(id)}})
      :sys.get_state(CameraStatus)

      assert CameraStatus.all()[id] == nil

      send(CameraStatus, {:config_changed, %{diff() | known: with_id(id)}})
      :sys.get_state(CameraStatus)

      assert CameraStatus.all()[id] == nil
    end)
  end

  # Every config server broadcasts on the one config topic, so an owner that
  # acted on a private test server's diff would prune this table against the
  # application snapshot that diff never moved.
  test "a diff from another config server is ignored", %{id: id} do
    CameraStatus.put(id, %{status: :running})

    send(CameraStatus, {:config_changed, %{diff() | server: :private_test_server}})
    :sys.get_state(CameraStatus)

    assert CameraStatus.all()[id]
  end

  # `Cairn.Native.Status` keeps reporting a camera's streams until the
  # asynchronous native reconfiguration lands, so a poll after the prune would
  # otherwise re-insert the row the prune removed.
  test "a write for a camera the snapshot does not name is dropped", %{id: id} do
    CameraStatus.set(id, :running)
    :sys.get_state(CameraStatus)

    assert CameraStatus.all()[id] == nil
  end

  test "a write for a camera the snapshot names lands", %{id: id} do
    with_snapshot_naming(id, fn ->
      CameraStatus.set(id, :running)
      :sys.get_state(CameraStatus)

      assert CameraStatus.get(id).status == :running
    end)
  end

  test "with no snapshot published every write lands", %{id: id} do
    without_snapshot(fn ->
      CameraStatus.set(id, :running)
      :sys.get_state(CameraStatus)

      assert CameraStatus.get(id).status == :running
    end)
  end

  test "put/2 lands whatever the snapshot names", %{id: id} do
    CameraStatus.put(id, %{status: :running})
    :sys.get_state(CameraStatus)

    assert CameraStatus.get(id).status == :running
  end

  # Sends the broadcast the owner subscribes to straight at it, rather than
  # publishing on the config topic: the other owners share that topic and
  # would prune the ids of whatever else the run has already started.
  defp prune_now do
    send(CameraStatus, {:config_changed, diff()})
    :sys.get_state(CameraStatus)
    :ok
  end

  # `known` is what the owner prunes against, and it rides the diff; the ids
  # the application config names are what the real broadcast would carry.
  defp diff do
    %{
      added: [],
      removed: [],
      changed: [],
      refreshed: [],
      server: Cairn.Config.Server,
      known: Cairn.Config.Server.known_ids()
    }
  end

  defp without(id), do: MapSet.delete(Cairn.Config.Server.known_ids(), id)
  defp with_id(id), do: MapSet.put(Cairn.Config.Server.known_ids(), id)

  # The published snapshot is the application's, so both helpers restore it.
  defp with_snapshot_naming(id, fun) do
    config = Cairn.Config.Server.get()
    swap_snapshot(%{config | cameras: [%Cairn.Config.Camera{id: id} | config.cameras]}, fun)
  end

  defp without_snapshot(fun), do: swap_snapshot(nil, fun)

  defp swap_snapshot(config, fun) do
    key = Cairn.Config.Server.snapshot_key(Cairn.Config.Server)
    restore = :persistent_term.get(key, nil)

    try do
      if config, do: :persistent_term.put(key, config), else: :persistent_term.erase(key)
      fun.()
    after
      if restore, do: :persistent_term.put(key, restore), else: :persistent_term.erase(key)
    end
  end
end
