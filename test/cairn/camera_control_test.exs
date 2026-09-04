defmodule Cairn.CameraControlTest do
  # Uses the globally-supervised Cairn.CameraControl. NOT async: the prune
  # tests empty the shared table down to the ids the test env's config names,
  # deleting control state concurrent suites rely on mid-test — the presence
  # suites' recording_enabled: false isolation in particular. The tests that
  # need an id the fleet does not have write the snapshot themselves, which is
  # process-global too.
  use ExUnit.Case, async: false

  alias Cairn.CameraControl
  alias Cairn.Config

  @defaults %{detection_enabled: true, recording_enabled: true, min_score: nil}

  test "defaults to on/on/no-override for an unknown camera" do
    assert CameraControl.get("cc_#{System.unique_integer([:positive])}") == @defaults
  end

  test "set merges partial attrs and returns the new control" do
    assert %{detection_enabled: false, recording_enabled: true, min_score: nil} =
             CameraControl.set("cam_a", %{detection_enabled: false})

    assert %{detection_enabled: false, min_score: 0.8} =
             CameraControl.set("cam_a", %{min_score: 0.8})

    on_exit(fn -> CameraControl.set("cam_a", @defaults) end)
  end

  test "set broadcasts on the control topic" do
    CameraControl.subscribe()
    on_exit(fn -> CameraControl.set("cam_a", @defaults) end)

    CameraControl.set("cam_a", %{recording_enabled: false})

    assert_receive {:camera_control, "cam_a", %{recording_enabled: false}}
  end

  test "ignores unknown attr keys" do
    on_exit(fn -> CameraControl.set("cam_a", @defaults) end)
    control = CameraControl.set("cam_a", %{bogus: 1, detection_enabled: false})
    refute Map.has_key?(control, :bogus)
    assert control.detection_enabled == false
  end

  test "a write for a camera the snapshot does not name is refused" do
    id = "cc_#{System.unique_integer([:positive])}"

    assert CameraControl.set(id, %{detection_enabled: false}) == {:error, :unknown_camera}
    assert CameraControl.get(id) == @defaults
  end

  # nil known ids is not an empty fleet: a server that has published no
  # snapshot cannot say the camera is unknown.
  test "a write is allowed while no snapshot is published" do
    id = "cc_#{System.unique_integer([:positive])}"

    without_snapshot(fn ->
      assert %{detection_enabled: false} = CameraControl.set(id, %{detection_enabled: false})
    end)

    prune_now()
  end

  # The whole ordering the design rests on, in one test: the config server
  # publishes before it applies and broadcasts after, so a write handled
  # before the publish lands and is pruned by the broadcast that follows, and
  # one handled after is refused. Nothing is marked, nothing is revived.
  test "a write before the publish is pruned; one after it is refused" do
    id = "cc_#{System.unique_integer([:positive])}"

    with_snapshot_naming(id, fn ->
      assert %{detection_enabled: false} = CameraControl.set(id, %{detection_enabled: false})
    end)

    # …and now the snapshot that drops it is published
    assert CameraControl.set(id, %{detection_enabled: false}) == {:error, :unknown_camera}

    prune_now()
    assert CameraControl.all()[id] == nil
  end

  # The delete's membership is frozen on the delete's diff, so the create that
  # overtook it in the snapshot cannot save the old overlay: pruning against
  # the moving snapshot here would leave the new camera wearing it.
  test "a delete handled after the same id was re-created still drops the overlay" do
    id = "cc_#{System.unique_integer([:positive])}"
    assert %{detection_enabled: false} = CameraControl.put(id, %{detection_enabled: false})

    with_snapshot_naming(id, fn ->
      send(CameraControl, {:config_changed, %{diff() | known: without(id)}})
      :sys.get_state(CameraControl)

      assert CameraControl.all()[id] == nil

      send(CameraControl, {:config_changed, %{diff() | known: with_id(id)}})
      :sys.get_state(CameraControl)

      assert CameraControl.all()[id] == nil
    end)
  end

  # Every config server broadcasts on the one config topic, so an owner that
  # acted on a private test server's diff would prune this table against the
  # application snapshot that diff never moved.
  test "a diff from another config server is ignored" do
    id = "cc_#{System.unique_integer([:positive])}"
    assert %{detection_enabled: false} = CameraControl.put(id, %{detection_enabled: false})

    send(CameraControl, {:config_changed, %{diff() | server: :private_test_server}})
    :sys.get_state(CameraControl)

    assert CameraControl.get(id).detection_enabled == false

    prune_now()
    assert CameraControl.all()[id] == nil
  end

  # Sends the broadcast the owner subscribes to straight at it, rather than
  # publishing on the config topic: the other owners share that topic and
  # would prune the ids of whatever else the run has already started.
  defp prune_now do
    send(CameraControl, {:config_changed, diff()})
    :sys.get_state(CameraControl)
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
      server: Config.Server,
      known: Config.Server.known_ids()
    }
  end

  defp without(id), do: MapSet.delete(Config.Server.known_ids(), id)
  defp with_id(id), do: MapSet.put(Config.Server.known_ids(), id)

  # The published snapshot is the application's, so both helpers restore it.
  defp with_snapshot_naming(id, fun) do
    config = Config.Server.get()
    swap_snapshot(%{config | cameras: [%Config.Camera{id: id} | config.cameras]}, fun)
  end

  defp without_snapshot(fun), do: swap_snapshot(nil, fun)

  defp swap_snapshot(config, fun) do
    key = Config.Server.snapshot_key(Config.Server)
    restore = :persistent_term.get(key, nil)

    try do
      if config, do: :persistent_term.put(key, config), else: :persistent_term.erase(key)
      fun.()
    after
      if restore, do: :persistent_term.put(key, restore), else: :persistent_term.erase(key)
    end
  end
end
