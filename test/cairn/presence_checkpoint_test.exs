defmodule Cairn.PresenceCheckpointTest do
  # Uses the globally-supervised owner and its shared table. NOT async: the
  # prune drops every row the test env's config does not name, and the
  # snapshot the write check reads is process-global.
  use ExUnit.Case, async: false

  alias Cairn.Event
  alias Cairn.PresenceCheckpoint

  # The rows of a camera that left the config have no recorder left to end
  # them, so the owner drops them itself when the config changes.
  test "a config change drops the rows of cameras the snapshot no longer names" do
    gone = unique_id()
    PresenceCheckpoint.put!(gone, event("e1", gone), [{nil, "person"}], self())
    PresenceCheckpoint.put("cam_a", event("e2", "cam_a"), [], self())

    on_exit(fn -> PresenceCheckpoint.delete("cam_a") end)

    prune_now()

    assert PresenceCheckpoint.get(gone) == nil
    assert {%Event{id: "e2"}, [], _pid, %{}} = PresenceCheckpoint.get("cam_a")
  end

  # A recorder arming its post window outlives `retire/1` — a late write would
  # otherwise re-create the row the prune just dropped.
  test "a write for a camera the snapshot does not name is dropped" do
    id = unique_id()

    PresenceCheckpoint.put(id, event("e1", id), [], self())

    assert PresenceCheckpoint.get(id) == nil
  end

  test "a write for a camera the snapshot names lands" do
    id = unique_id()

    with_snapshot_naming(id, fn ->
      PresenceCheckpoint.put(id, event("e1", id), [], self())
      assert {%Event{id: "e1"}, [], _pid, %{}} = PresenceCheckpoint.get(id)
    end)

    prune_now()
  end

  test "with no snapshot published every write lands" do
    id = unique_id()

    without_snapshot(fn ->
      PresenceCheckpoint.put(id, event("e1", id), [], self())
      assert {%Event{id: "e1"}, [], _pid, %{}} = PresenceCheckpoint.get(id)
    end)

    prune_now()
  end

  # The delete's membership is frozen on the delete's diff, so the create that
  # overtook it in the snapshot cannot save the old row: pruning against the
  # moving snapshot here would hand the re-created camera a checkpoint whose
  # event and extractor belong to the camera it replaced.
  test "a delete handled after the same id was re-created still drops the row" do
    id = unique_id()
    PresenceCheckpoint.put!(id, event("e1", id), [], self())

    with_snapshot_naming(id, fn ->
      send(PresenceCheckpoint, {:config_changed, %{diff() | known: without(id)}})
      :sys.get_state(PresenceCheckpoint)

      assert PresenceCheckpoint.get(id) == nil

      send(PresenceCheckpoint, {:config_changed, %{diff() | known: with_id(id)}})
      :sys.get_state(PresenceCheckpoint)

      assert PresenceCheckpoint.get(id) == nil
    end)
  end

  # Every config server broadcasts on the one config topic, so an owner that
  # acted on a private test server's diff would prune this table against the
  # application snapshot that diff never moved.
  test "a diff from another config server is ignored" do
    id = unique_id()
    on_exit(fn -> PresenceCheckpoint.delete(id) end)
    PresenceCheckpoint.put!(id, event("e3", id), [], self())

    send(PresenceCheckpoint, {:config_changed, %{diff() | server: :private_test_server}})
    :sys.get_state(PresenceCheckpoint)

    assert PresenceCheckpoint.get(id)
  end

  defp unique_id, do: "prck_#{System.unique_integer([:positive])}"

  defp event(id, camera_id),
    do: %Event{id: id, camera_id: camera_id, started_at: DateTime.utc_now()}

  # Straight at the owner rather than on the config topic: the other owners
  # share that topic and would prune the ids of whatever else is running.
  defp prune_now do
    send(PresenceCheckpoint, {:config_changed, diff()})
    :sys.get_state(PresenceCheckpoint)
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
