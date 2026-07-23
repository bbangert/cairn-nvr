defmodule CairnWeb.MediaControllerTest do
  use CairnWeb.ConnCase, async: false

  alias Cairn.Events

  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_media_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    clip = Path.join(dir, "clip.mp4")
    File.write!(clip, String.duplicate("a", 100) <> String.duplicate("b", 100))

    snapshot = Path.join(dir, "snap.jpg")
    File.write!(snapshot, "JPGDATA")

    event = %Cairn.Event{
      id: Ecto.UUID.generate(),
      camera_id: "cam_a",
      started_at: DateTime.utc_now()
    }

    {:ok, _} = Events.create_active(event, clip)
    {:ok, _} = Events.set_snapshot(event.id, snapshot)

    %{event: event}
  end

  test "serves the whole clip without a range header", %{conn: conn, event: event} do
    conn = get(conn, "/media/events/#{event.id}")
    assert response(conn, 200)
    assert byte_size(conn.resp_body) == 200
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
  end

  test "serves 206 partial content for ranges", %{conn: conn, event: event} do
    conn =
      conn
      |> put_req_header("range", "bytes=0-99")
      |> get("/media/events/#{event.id}")

    assert response(conn, 206)
    assert conn.resp_body == String.duplicate("a", 100)
    assert get_resp_header(conn, "content-range") == ["bytes 0-99/200"]
  end

  test "open-ended and suffix ranges", %{conn: conn, event: event} do
    conn1 = conn |> put_req_header("range", "bytes=100-") |> get("/media/events/#{event.id}")
    assert response(conn1, 206)
    assert conn1.resp_body == String.duplicate("b", 100)

    conn2 = conn |> put_req_header("range", "bytes=-50") |> get("/media/events/#{event.id}")
    assert response(conn2, 206)
    assert conn2.resp_body == String.duplicate("b", 50)
    assert get_resp_header(conn2, "content-range") == ["bytes 150-199/200"]
  end

  test "unsatisfiable range is 416", %{conn: conn, event: event} do
    conn = conn |> put_req_header("range", "bytes=999-") |> get("/media/events/#{event.id}")
    assert response(conn, 416)
    assert get_resp_header(conn, "content-range") == ["bytes */200"]
  end

  test "serves snapshots and 404s", %{conn: conn, event: event} do
    assert conn |> get("/media/snapshots/#{event.id}") |> response(200) == "JPGDATA"
    assert conn |> get("/media/events/#{Ecto.UUID.generate()}") |> response(404)
    assert conn |> get("/media/snapshots/#{Ecto.UUID.generate()}") |> response(404)
  end
end
