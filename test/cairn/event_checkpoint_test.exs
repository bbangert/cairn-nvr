defmodule Cairn.EventCheckpointTest do
  # Uses the globally-supervised owner and its shared table. NOT async: the
  # prune drops every row the test env's config does not name.
  use ExUnit.Case, async: false

  alias Cairn.Event
  alias Cairn.EventCheckpoint

  # The rows of a camera that left the config have no tracker left to end
  # them, so the owner drops them itself when the config changes.
  test "a config change drops the rows of cameras the snapshot no longer names" do
    gone = "evck_#{System.unique_integer([:positive])}"
    EventCheckpoint.put(gone, %Event{id: "e1", camera_id: gone, started_at: DateTime.utc_now()})

    EventCheckpoint.put("cam_a", %Event{
      id: "e2",
      camera_id: "cam_a",
      started_at: DateTime.utc_now()
    })

    on_exit(fn -> EventCheckpoint.delete("cam_a") end)

    prune_now()

    assert EventCheckpoint.get(gone) == nil
    assert {%Event{id: "e2"}, []} = EventCheckpoint.get("cam_a")
  end

  # Every config server broadcasts on the one config topic, so an owner that
  # acted on a private test server's diff would prune this table against the
  # application snapshot that diff never moved.
  test "a diff from another config server is ignored" do
    id = "evck_#{System.unique_integer([:positive])}"
    on_exit(fn -> EventCheckpoint.delete(id) end)
    EventCheckpoint.put(id, %Event{id: "e3", camera_id: id, started_at: DateTime.utc_now()})

    send(EventCheckpoint, {:config_changed, %{diff() | server: :private_test_server}})
    :sys.get_state(EventCheckpoint)

    assert EventCheckpoint.get(id)
  end

  # Straight at the owner rather than on the config topic: the other owners
  # share that topic and would prune the ids of whatever else is running.
  defp prune_now do
    send(EventCheckpoint, {:config_changed, diff()})
    :sys.get_state(EventCheckpoint)
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
