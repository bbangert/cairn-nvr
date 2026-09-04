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

  # Straight at the owner rather than on the config topic: the other owners
  # share that topic and would prune the ids of whatever else is running.
  defp prune_now do
    send(
      EventCheckpoint,
      {:config_changed, %{added: [], removed: [], changed: [], refreshed: []}}
    )

    :sys.get_state(EventCheckpoint)
    :ok
  end
end
