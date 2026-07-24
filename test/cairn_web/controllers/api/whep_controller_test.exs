defmodule CairnWeb.Api.WhepControllerTest do
  # exercises the WHEP HTTP surface end-to-end (real ExWebRTC negotiation);
  # touches the global WebRTC.Supervisor, so async: false
  use CairnWeb.ConnCase, async: false

  alias ExWebRTC.PeerConnection

  @token "test-ha-token"

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "authorization", "Bearer #{@token}")}
  end

  # A non-trickle client offer: gather ICE fully, then use the local description.
  defp nontrickle_offer do
    {:ok, pc} = PeerConnection.start_link(video_codecs: [:h264])
    {:ok, _tr} = PeerConnection.add_transceiver(pc, :video, direction: :recvonly)
    {:ok, offer} = PeerConnection.create_offer(pc)
    :ok = PeerConnection.set_local_description(pc, offer)
    assert_receive {:ex_webrtc, ^pc, {:ice_gathering_state_change, :complete}}, 5_000
    PeerConnection.get_local_description(pc).sdp
  end

  defp sdp_post(conn, path, sdp) do
    conn |> put_req_header("content-type", "application/sdp") |> post(path, sdp)
  end

  test "requires the token (401) before doing any work" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/sdp")
      |> post("/api/cameras/cam_a/webrtc", "v=0")

    assert json_response(conn, 401)
  end

  test "404s an unknown camera", %{conn: conn} do
    conn = sdp_post(conn, "/api/cameras/nope/webrtc", "v=0")
    assert json_response(conn, 404)
  end

  test "400s a missing offer body", %{conn: conn} do
    conn = sdp_post(conn, "/api/cameras/cam_a/webrtc", "")
    assert json_response(conn, 400)
  end

  test "201 with an answer SDP + Location, then DELETE tears it down", %{conn: conn} do
    post_conn = sdp_post(conn, "/api/cameras/cam_a/webrtc", nontrickle_offer())

    assert post_conn.status == 201
    assert ["application/sdp" <> _] = get_resp_header(post_conn, "content-type")
    assert post_conn.resp_body =~ "v=0"
    assert post_conn.resp_body =~ "a=sendonly"
    assert [location] = get_resp_header(post_conn, "location")
    assert location =~ ~r"^/api/webrtc/[\w-]+$"

    # DELETE the resource → 204, then a repeat DELETE → 404
    del1 = delete(conn, location)
    assert response(del1, 204)

    del2 = delete(conn, location)
    assert json_response(del2, 404)
  end

  test "accepts a JSON {sdp} offer as well", %{conn: conn} do
    offer = nontrickle_offer()
    post_conn = post(conn, "/api/cameras/cam_a/webrtc", %{sdp: offer})

    assert post_conn.status == 201
    [location] = get_resp_header(post_conn, "location")
    assert response(delete(conn, location), 204)
  end

  # 503 (max_children) is covered by WebRTC.Supervisor's cap; exercising it
  # would require standing up 32 live PeerConnections and is left to manual/load
  # testing.
end
