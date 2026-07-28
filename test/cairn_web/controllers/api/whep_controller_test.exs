defmodule CairnWeb.Api.WhepControllerTest do
  # exercises the WHEP HTTP surface end-to-end (real ExWebRTC negotiation);
  # touches the global WebRTC.Supervisor, so async: false.
  #
  # async: false is also load-bearing for a second reason: the stale-entry test
  # suspends `Cairn.Registry`'s partition, a process the whole application
  # shares. It is hermetic only because ExUnit runs every async module to
  # completion before any sync one, so nothing else is registering while the
  # partition is down. Do not flip this file to async: true.
  use CairnWeb.ConnCase, async: false

  import Cairn.RegistryHelpers, only: [suspend_registry_reaping: 0]

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

  test "413s an oversized raw offer (distinct from missing)", %{conn: conn} do
    oversized = String.duplicate("a", 70_000)
    conn = sdp_post(conn, "/api/cameras/cam_a/webrtc", oversized)
    assert json_response(conn, 413)["error"] =~ "too large"
  end

  test "413s an oversized JSON {sdp} offer too", %{conn: conn} do
    conn = post(conn, "/api/cameras/cam_a/webrtc", %{sdp: String.duplicate("a", 70_000)})
    assert json_response(conn, 413)["error"] =~ "too large"
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

  test "404s a DELETE for an id that never existed", %{conn: conn} do
    assert json_response(delete(conn, "/api/webrtc/never-existed"), 404)
  end

  # Registry unregistration rides the async EXIT the registry partition sends
  # itself, so a `whereis` right after a teardown can still hand back the dead
  # session. Suspending the partition holds that window open deterministically —
  # under load it opened on its own and the repeat DELETE answered 204.
  #
  # The window is opened before the *first* DELETE on purpose: that teardown is
  # the only thing that can create the stale entry.
  test "repeat DELETE 404s while the registry still lists the dead session", %{conn: conn} do
    post_conn = sdp_post(conn, "/api/cameras/cam_a/webrtc", nontrickle_offer())
    assert post_conn.status == 201
    assert [location] = get_resp_header(post_conn, "location")
    whep_id = Path.basename(location)

    suspend_registry_reaping()

    assert response(delete(conn, location), 204)

    pid = Cairn.Registry.whereis(whep_id, :whep)
    assert is_pid(pid)
    refute Process.alive?(pid)

    assert json_response(delete(conn, location), 404)
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
