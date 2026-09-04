defmodule Cairn.PresenceCheckpointTest do
  # Uses the globally-supervised owner and its shared table. NOT async: the
  # prune drops every row the test env's config does not name.
  use ExUnit.Case, async: false

  alias Cairn.Event
  alias Cairn.PresenceCheckpoint

  # The rows of a camera that left the config have no recorder left to end
  # them, so the owner drops them itself when the config changes.
  test "a config change drops the rows of cameras the snapshot no longer names" do
    gone = "prck_#{System.unique_integer([:positive])}"

    PresenceCheckpoint.put(
      gone,
      %Event{id: "e1", camera_id: gone, started_at: DateTime.utc_now()},
      [{nil, "person"}],
      self()
    )

    PresenceCheckpoint.put(
      "cam_a",
      %Event{id: "e2", camera_id: "cam_a", started_at: DateTime.utc_now()},
      [],
      self()
    )

    on_exit(fn -> PresenceCheckpoint.delete("cam_a") end)

    prune_now()

    assert PresenceCheckpoint.get(gone) == nil
    assert {%Event{id: "e2"}, [], _pid, %{}} = PresenceCheckpoint.get("cam_a")
  end

  # Every config server broadcasts on the one config topic, so an owner that
  # acted on a private test server's diff would prune this table against the
  # application snapshot that diff never moved.
  test "a diff from another config server is ignored" do
    id = "prck_#{System.unique_integer([:positive])}"
    on_exit(fn -> PresenceCheckpoint.delete(id) end)

    PresenceCheckpoint.put(
      id,
      %Event{id: "e3", camera_id: id, started_at: DateTime.utc_now()},
      [],
      self()
    )

    send(PresenceCheckpoint, {:config_changed, %{diff() | server: :private_test_server}})
    :sys.get_state(PresenceCheckpoint)

    assert PresenceCheckpoint.get(id)
  end

  # Straight at the owner rather than on the config topic: the other owners
  # share that topic and would prune the ids of whatever else is running.
  defp prune_now do
    send(PresenceCheckpoint, {:config_changed, diff()})
    :sys.get_state(PresenceCheckpoint)
    :ok
  end

  defp diff do
    %{
      added: [],
      removed: [],
      changed: [],
      refreshed: [],
      server: Cairn.Config.Server
    }
  end
end
