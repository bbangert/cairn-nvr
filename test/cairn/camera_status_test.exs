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

    CameraStatus.set(id, :running)
    assert_receive {:camera_status, ^id, %{status: :running}}

    CameraStatus.set_plugin_status(id, %{"state" => "ready", "detail" => "model loaded"})
    assert_receive {:camera_status, ^id, info}
    assert info.status == :running
    assert info.plugin_status == %{"state" => "ready", "detail" => "model loaded"}
  end

  test "set/merge accumulate and broadcast", %{id: id} do
    CameraStatus.subscribe()

    CameraStatus.set(id, :running)
    assert_receive {:camera_status, ^id, %{status: :running}}

    CameraStatus.set_probe(id, %{codec: "h264", fps: 20.0})
    assert_receive {:camera_status, ^id, info}
    assert info.status == :running
    assert info.probe.codec == "h264"

    assert CameraStatus.get(id) == info
    assert CameraStatus.all()[id] == info
  end

  # The owner prunes its own table in its own callback: nobody hands it a list
  # of ids, it asks the published snapshot which cameras exist.
  test "a config change drops the cameras the snapshot no longer names", %{id: id} do
    CameraStatus.set(id, :running)
    CameraStatus.set("cam_a", :running)

    prune_now()

    assert CameraStatus.all()[id] == nil
    assert CameraStatus.all()["cam_a"]
  end

  # Sends the broadcast the owner subscribes to straight at it, rather than
  # publishing on the config topic: the other owners share that topic and
  # would prune the ids of whatever else the run has already started.
  defp prune_now do
    send(CameraStatus, {:config_changed, %{added: [], removed: [], changed: [], refreshed: []}})
    :sys.get_state(CameraStatus)
    :ok
  end
end
