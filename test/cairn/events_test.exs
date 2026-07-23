defmodule Cairn.EventsTest do
  use Cairn.DataCase, async: true

  alias Cairn.Events

  defp seed(camera_id, days_ago, labels, status \\ :finalized) do
    id = Ecto.UUID.generate()
    started = DateTime.add(DateTime.utc_now(), -days_ago * 86_400)

    event = %Cairn.Event{
      id: id,
      camera_id: camera_id,
      started_at: started,
      ended_at: DateTime.add(started, 30),
      status: status,
      max_scores: Map.new(labels, &{&1, 0.8})
    }

    {:ok, row} = Events.create_active(event, "/tmp/#{id}.mp4")

    if status == :finalized do
      {:ok, row} = Events.finalize(%{event | status: :finalized}, 100)
      row
    else
      row
    end
  end

  test "list filters by camera, label and time; paginates newest-first" do
    seed("cam_a", 1, ["person"])
    seed("cam_a", 2, ["car"])
    seed("cam_b", 3, ["person", "car"])

    assert %{total: 3, events: [e1, e2, e3]} = Events.list()
    assert DateTime.compare(e1.started_at, e2.started_at) == :gt
    assert DateTime.compare(e2.started_at, e3.started_at) == :gt

    assert %{total: 2} = Events.list(camera: "cam_a")
    assert %{total: 2} = Events.list(label: "person")
    assert %{total: 1} = Events.list(camera: "cam_a", label: "person")

    from = DateTime.add(DateTime.utc_now(), -2 * 86_400 - 3600)
    assert %{total: 2} = Events.list(from: from)
    assert %{total: 1} = Events.list(to: from)

    assert %{events: [_], total: 3, page: 2} = Events.list(page: 2, page_size: 1)
    assert %{events: []} = Events.list(page: 9, page_size: 2)
  end

  test "known_labels collects distinct labels" do
    seed("cam_a", 1, ["person"])
    seed("cam_b", 2, ["car", "person"])

    assert Events.known_labels() == ["car", "person"]
  end

  test "oldest_for_cleanup skips active events" do
    seed("cam_a", 5, ["person"], :active)
    old = seed("cam_a", 9, ["person"])

    assert [%{id: id}] = Events.oldest_for_cleanup(1)
    assert id == old.id
  end
end
