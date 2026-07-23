defmodule CairnWeb.WebRTC.SessionTest do
  use ExUnit.Case, async: false

  alias CairnWeb.WebRTC.Session
  alias ExWebRTC.PeerConnection

  defp browser_offer do
    {:ok, pc} = PeerConnection.start_link(video_codecs: [:h264])
    {:ok, _tr} = PeerConnection.add_transceiver(pc, :video, direction: :recvonly)
    {:ok, offer} = PeerConnection.create_offer(pc)
    :ok = PeerConnection.set_local_description(pc, offer)
    {pc, offer}
  end

  test "answers a recvonly H264 offer with a sendonly H264 answer" do
    {_browser, offer} = browser_offer()

    session = start_supervised!({Session, camera_id: "cam_a", owner: self()})

    assert {:ok, answer_sdp} = Session.handle_offer(session, offer.sdp)
    assert answer_sdp =~ "H264"
    assert answer_sdp =~ "a=sendonly"
  end

  test "bad offers are rejected without crashing" do
    session = start_supervised!({Session, camera_id: "cam_a", owner: self()})

    assert {:error, :bad_offer} = Session.handle_offer(session, "not sdp at all")
    assert Process.alive?(session)
  end

  test "malformed ice candidates are dropped" do
    session = start_supervised!({Session, camera_id: "cam_a", owner: self()})
    :ok = Session.add_ice(session, %{"weird" => "shape"})
    assert Process.alive?(session)
  end

  test "session stops when the owner (channel) dies" do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, session} = Session.start_link(camera_id: "cam_a", owner: owner)
    ref = Process.monitor(session)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2_000
  end
end
