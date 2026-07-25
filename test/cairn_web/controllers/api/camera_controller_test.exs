defmodule CairnWeb.Api.CameraControllerTest do
  # touches the global Cairn.CameraControl ETS for cam_a; reset on exit
  use CairnWeb.ConnCase, async: false

  alias Cairn.CameraControl

  @token "test-ha-token"

  setup %{conn: conn} do
    on_exit(fn ->
      CameraControl.set("cam_a", %{
        detection_enabled: true,
        recording_enabled: true,
        min_score: nil
      })
    end)

    {:ok, conn: put_req_header(conn, "authorization", "Bearer #{@token}")}
  end

  test "index lists configured cameras and never leaks rtsp_url", %{conn: conn} do
    body = conn |> get("/api/cameras") |> json_response(200)

    assert %{"cameras" => cameras} = body
    ids = Enum.map(cameras, & &1["id"])
    assert "cam_a" in ids and "cam_b" in ids
    refute Enum.any?(cameras, &Map.has_key?(&1, "rtsp_url"))

    cam_a = Enum.find(cameras, &(&1["id"] == "cam_a"))
    # cam_a has no plugin in the fixture
    assert cam_a["detection"] == false
    assert cam_a["control"]["detection_enabled"] == true
    assert cam_a["windows"]["post_seconds"] == 10
  end

  test "index does not 500 when a camera probe is an error tuple", %{conn: conn} do
    # CameraStatus stores probe failures as {:error, term}, which Jason can't
    # encode — the list must sanitize it, not crash.
    Cairn.CameraStatus.set_probe("cam_a", {:error, :timeout})
    # set_probe is an async cast; flush it so the ETS write lands before we read
    _ = :sys.get_state(Cairn.CameraStatus)
    on_exit(fn -> Cairn.CameraStatus.set_probe("cam_a", nil) end)

    body = conn |> get("/api/cameras") |> json_response(200)
    cam_a = Enum.find(body["cameras"], &(&1["id"] == "cam_a"))
    assert cam_a["probe"] == %{"error" => ":timeout"}
  end

  test "control updates detection and min_score override", %{conn: conn} do
    body =
      conn
      |> post("/api/cameras/cam_a/control", %{detection_enabled: false, min_score: 0.7})
      |> json_response(200)

    assert body["id"] == "cam_a"
    assert body["control"]["detection_enabled"] == false
    assert body["control"]["min_score"] == 0.7
    # confirms it persisted to the store
    assert CameraControl.get("cam_a").min_score == 0.7
  end

  test "control clears the override with null min_score", %{conn: conn} do
    CameraControl.set("cam_a", %{min_score: 0.9})

    body =
      conn
      |> post("/api/cameras/cam_a/control", %{min_score: nil})
      |> json_response(200)

    assert body["control"]["min_score"] == nil
  end

  test "control rejects an out-of-range min_score", %{conn: conn} do
    body = conn |> post("/api/cameras/cam_a/control", %{min_score: 2.0}) |> json_response(422)
    assert body["error"] =~ "min_score"
  end

  test "control rejects a non-boolean toggle", %{conn: conn} do
    assert conn
           |> post("/api/cameras/cam_a/control", %{detection_enabled: "yes"})
           |> json_response(422)
  end

  test "control 404s an unknown camera", %{conn: conn} do
    assert conn
           |> post("/api/cameras/nope/control", %{detection_enabled: false})
           |> json_response(404)
  end
end
