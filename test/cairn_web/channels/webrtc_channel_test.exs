defmodule CairnWeb.WebRTCChannelTest do
  use CairnWeb.ChannelCase, async: false

  alias ExWebRTC.PeerConnection

  test "join + offer/answer signaling round-trip" do
    {:ok, _, socket} =
      CairnWeb.UserSocket
      |> socket("user", %{})
      |> subscribe_and_join(CairnWeb.WebRTCChannel, "webrtc:cam_a")

    {:ok, pc} = PeerConnection.start_link(video_codecs: [:h264])
    {:ok, _tr} = PeerConnection.add_transceiver(pc, :video, direction: :recvonly)
    {:ok, offer} = PeerConnection.create_offer(pc)
    :ok = PeerConnection.set_local_description(pc, offer)

    ref = push(socket, "offer", %{"sdp" => offer.sdp})
    assert_reply ref, :ok, %{sdp: answer_sdp}, 5_000
    assert answer_sdp =~ "H264"
  end

  test "unknown camera is rejected" do
    assert {:error, %{reason: "unknown camera"}} =
             CairnWeb.UserSocket
             |> socket("user", %{})
             |> subscribe_and_join(CairnWeb.WebRTCChannel, "webrtc:nope")
  end
end
