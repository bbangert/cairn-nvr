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

  # A presence-born event (`Cairn.PresenceRecorder`): identity-less entries and
  # trigger, labels merged per camera, no track rows behind it. D-E7 says nothing
  # on the wire distinguishes it, which is what these assertions are for.
  defp create_presence_born(camera_id) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    event = %Cairn.Event{
      id: id,
      camera_id: camera_id,
      started_at: now,
      labels: [%{t: 0.0, label: "person", score: 0.82, object_id: nil}],
      max_scores: %{"person" => 0.82},
      max_score: 0.82,
      trigger: %{
        t: 1.4,
        label: "person",
        score: 0.82,
        bbox: [0.1, 0.2, 0.3, 0.4],
        object_id: nil
      }
    }

    {:ok, _} = Events.create_active(event, "/data/events/#{camera_id}/#{id}.mp4")
    {event, id}
  end

  test "a presence-born event shapes like any other", %{conn: conn} do
    {event, id} = create_presence_born("cam_tier1")
    {:ok, _} = Events.finalize(%{event | ended_at: DateTime.add(event.started_at, 12)}, 4242)

    body = conn |> get("/api/events/#{id}") |> json_response(200)

    assert body["id"] == id
    assert body["camera_id"] == "cam_tier1"
    assert body["status"] == "finalized"
    assert body["labels"] == %{"person" => 0.82}
    assert body["max_score"] == 0.82
    assert body["bytes"] == 4242
    assert body["clip_url"] == "/api/media/events/#{id}"
    refute Map.has_key?(body, "path")
    # the trigger's identity column is empty on this lane, and the row API does
    # not carry the trigger at all — the field set is the tracked lane's exactly
    assert Map.keys(body) |> Enum.sort() ==
             ~w(bytes camera_id clip_url ended_at id labels max_score snapshot_url started_at status)
  end

  test "a presence-born event is listed while it is still recording", %{conn: conn} do
    # The extractor writes the `active` row at open, so a segment is readable
    # from the moment it starts — including one a `max_event` cap just opened.
    {_event, id} = create_presence_born("cam_tier1")

    body = conn |> get("/api/events?camera=cam_tier1") |> json_response(200)

    row = Enum.find(body["events"], &(&1["id"] == id))
    assert row["status"] == "active"
    assert row["ended_at"] == nil
    # `path` is written at open, so the clip is advertised while it grows
    assert row["clip_url"] == "/api/media/events/#{id}"
    assert row["snapshot_url"] == nil
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
