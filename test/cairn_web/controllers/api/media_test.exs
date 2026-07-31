defmodule CairnWeb.Api.MediaTest do
  # /api/media/* reuses MediaController under a token-authed pipeline that must
  # NOT format-negotiate (a player sends Accept: video/mp4 / image/jpeg).
  use CairnWeb.ConnCase, async: false

  alias Cairn.Events

  @token "test-ha-token"

  setup %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "cairn_api_media_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    clip = Path.join(dir, "clip.mp4")
    File.write!(clip, String.duplicate("m", 128))
    snap = Path.join(dir, "snap.jpg")
    File.write!(snap, "JPGDATA")

    event = %Cairn.Event{
      id: Ecto.UUID.generate(),
      camera_id: "cam_a",
      started_at: DateTime.utc_now()
    }

    {:ok, _} = Events.create_active(event, clip)
    {:ok, _} = Events.set_snapshot(event.id, snap)

    {:ok, conn: put_req_header(conn, "authorization", "Bearer #{@token}"), event: event, dir: dir}
  end

  test "serves an mp4 clip when the client sends Accept: video/mp4", %{conn: conn, event: event} do
    conn =
      conn
      |> put_req_header("accept", "video/mp4")
      |> get("/api/media/events/#{event.id}")

    # the point: a media Accept header must not 406 on the :api_media pipeline
    assert response(conn, 200)
    assert ["video/mp4" <> _] = get_resp_header(conn, "content-type")
  end

  test "serves a jpg snapshot when the client sends Accept: image/jpeg", %{
    conn: conn,
    event: event
  } do
    conn =
      conn
      |> put_req_header("accept", "image/jpeg")
      |> get("/api/media/snapshots/#{event.id}")

    assert response(conn, 200)
    assert ["image/jpeg" <> _] = get_resp_header(conn, "content-type")
  end

  test "serves the track sidecar with a token", %{conn: conn, event: event, dir: dir} do
    File.write!(Path.join(dir, "clip.tracks"), "TRACKBYTES")

    conn = get(conn, "/api/media/events/#{event.id}/tracks")

    assert response(conn, 200) == "TRACKBYTES"
    assert get_resp_header(conn, "content-type") == ["application/vnd.msgpack"]
    assert get_resp_header(conn, "content-encoding") == ["gzip"]
  end

  test "still requires the token", %{event: event, dir: dir} do
    File.write!(Path.join(dir, "clip.tracks"), "TRACKBYTES")

    conn =
      build_conn()
      |> put_req_header("accept", "video/mp4")
      |> get("/api/media/events/#{event.id}")

    assert json_response(conn, 401)

    # the sidecar is behind the same pipeline — a readable file on disk is not
    # a way around the token
    tracks = get(build_conn(), "/api/media/events/#{event.id}/tracks")
    assert json_response(tracks, 401)
  end
end
