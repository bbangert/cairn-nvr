defmodule CairnWeb.Api.EventControllerTest do
  use CairnWeb.ConnCase, async: false

  alias Cairn.Events

  @token "test-ha-token"

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "authorization", "Bearer #{@token}")}
  end

  defp create_event(camera_id \\ "cam_a") do
    id = Ecto.UUID.generate()

    event = %Cairn.Event{
      id: id,
      camera_id: camera_id,
      started_at: DateTime.utc_now(),
      max_score: 0.9
    }

    {:ok, _} = Events.create_active(event, "/data/events/#{camera_id}/#{id}.mp4")
    {:ok, _} = Events.finalize(%{event | ended_at: DateTime.utc_now()}, 1234)
    {:ok, _} = Events.set_snapshot(id, "/data/snap/#{id}.jpg")
    id
  end

  test "index returns events with media urls and no on-disk paths", %{conn: conn} do
    id = create_event()

    body = conn |> get("/api/events") |> json_response(200)

    assert %{"events" => events, "page" => 1, "total" => total} = body
    assert total >= 1

    event = Enum.find(events, &(&1["id"] == id))
    assert event["clip_url"] == "/api/media/events/#{id}"
    assert event["snapshot_url"] == "/api/media/snapshots/#{id}"
    refute Map.has_key?(event, "path")
    refute Map.has_key?(event, "snapshot_path")
  end

  test "index filters by camera", %{conn: conn} do
    _a = create_event("cam_a")
    b = create_event("cam_b")

    body = conn |> get("/api/events?camera=cam_b") |> json_response(200)
    ids = Enum.map(body["events"], & &1["id"])
    assert b in ids
    assert Enum.all?(body["events"], &(&1["camera_id"] == "cam_b"))
  end

  test "show returns one event", %{conn: conn} do
    id = create_event()
    body = conn |> get("/api/events/#{id}") |> json_response(200)
    assert body["id"] == id
    assert body["clip_url"] == "/api/media/events/#{id}"
  end

  test "show 404s an unknown id", %{conn: conn} do
    assert conn |> get("/api/events/#{Ecto.UUID.generate()}") |> json_response(404)
  end

  test "labels endpoint returns known labels", %{conn: conn} do
    assert %{"labels" => labels} = conn |> get("/api/labels") |> json_response(200)
    assert is_list(labels)
  end
end
