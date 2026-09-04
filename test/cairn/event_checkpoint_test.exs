defmodule Cairn.EventCheckpointTest do
  # Uses the globally-supervised owner and its shared table. NOT async: the
  # prune drops every row the test env's config does not name, and the
  # snapshot the write check reads is process-global.
  use ExUnit.Case, async: false

  alias Cairn.Event
  alias Cairn.EventCheckpoint

  # The rows of a camera that left the config have no tracker left to end
  # them, so the owner drops them itself when the config changes.
  test "a config change drops the rows of cameras the snapshot no longer names" do
    gone = unique_id()
    EventCheckpoint.put!(gone, event("e1", gone))
    EventCheckpoint.put("cam_a", event("e2", "cam_a"))

    on_exit(fn -> EventCheckpoint.delete("cam_a") end)

    prune_now()

    assert EventCheckpoint.get(gone) == nil
    assert {%Event{id: "e2"}, []} = EventCheckpoint.get("cam_a")
  end

  # A tracker outlives the camera's removal — a late `:camera_stopped` would
  # otherwise re-create the row the prune just dropped.
  test "a write for a camera the snapshot does not name is dropped" do
    id = unique_id()

    EventCheckpoint.put(id, event("e1", id))

    assert EventCheckpoint.get(id) == nil
  end

  test "a write for a camera the snapshot names lands" do
    id = unique_id()

    with_snapshot_naming(id, fn ->
      EventCheckpoint.put(id, event("e1", id))
      assert {%Event{id: "e1"}, []} = EventCheckpoint.get(id)
    end)

    prune_now()
  end

  test "with no snapshot published every write lands" do
    id = unique_id()

    without_snapshot(fn ->
      EventCheckpoint.put(id, event("e1", id))
      assert {%Event{id: "e1"}, []} = EventCheckpoint.get(id)
    end)

    prune_now()
  end

  # The delete's membership is frozen on the delete's diff, so the create that
  # overtook it in the snapshot cannot save the old row: pruning against the
  # moving snapshot here would hand the re-created camera a checkpoint whose
  # event and tracks belong to the camera it replaced.
  test "a delete handled after the same id was re-created still drops the row" do
    id = unique_id()
    EventCheckpoint.put!(id, event("e1", id))

    with_snapshot_naming(id, fn ->
      send(EventCheckpoint, {:config_changed, %{diff() | known: without(id)}})
      :sys.get_state(EventCheckpoint)

      assert EventCheckpoint.get(id) == nil

      send(EventCheckpoint, {:config_changed, %{diff() | known: with_id(id)}})
      :sys.get_state(EventCheckpoint)

      assert EventCheckpoint.get(id) == nil
    end)
  end

  # Every config server broadcasts on the one config topic, so an owner that
  # acted on a private test server's diff would prune this table against the
  # application snapshot that diff never moved.
  test "a diff from another config server is ignored" do
    id = unique_id()
    on_exit(fn -> EventCheckpoint.delete(id) end)
    EventCheckpoint.put!(id, event("e3", id))

    send(EventCheckpoint, {:config_changed, %{diff() | server: :private_test_server}})
    :sys.get_state(EventCheckpoint)

    assert EventCheckpoint.get(id)
  end

  defp unique_id, do: "evck_#{System.unique_integer([:positive])}"

  defp event(id, camera_id),
    do: %Event{id: id, camera_id: camera_id, started_at: DateTime.utc_now()}

  # Straight at the owner rather than on the config topic: the other owners
  # share that topic and would prune the ids of whatever else is running.
  defp prune_now do
    send(EventCheckpoint, {:config_changed, diff()})
    :sys.get_state(EventCheckpoint)
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
