defmodule CairnWeb.WebRTC.SessionTest do
  use ExUnit.Case, async: false

  alias CairnWeb.WebRTC.Session
  alias ExWebRTC.PeerConnection
  alias ExWebRTC.SessionDescription

  defp browser_offer do
    {:ok, pc} = PeerConnection.start_link(video_codecs: [:h264])
    {:ok, _tr} = PeerConnection.add_transceiver(pc, :video, direction: :recvonly)
    {:ok, offer} = PeerConnection.create_offer(pc)
    :ok = PeerConnection.set_local_description(pc, offer)
    {pc, offer}
  end

  # A non-trickle client: gather ICE to completion, then use the finished
  # local description (candidates embedded) as the offer — what a WHEP client does.
  defp nontrickle_offer do
    {pc, _offer} = browser_offer()
    assert_receive {:ex_webrtc, ^pc, {:ice_gathering_state_change, :complete}}, 5_000
    offer = PeerConnection.get_local_description(pc)
    {pc, offer.sdp}
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

  describe "WHEP (self-owned, non-trickle)" do
    defp start_whep(whep_id) do
      start_supervised!(
        {Session, camera_id: "cam_a", owner: nil, whep_id: whep_id},
        id: {:whep, whep_id}
      )
    end

    test "answers a non-trickle offer with candidates embedded in the SDP" do
      {_client, offer_sdp} = nontrickle_offer()
      whep_id = "whep_#{System.unique_integer([:positive])}"
      session = start_whep(whep_id)

      assert {:ok, answer_sdp} = Session.handle_offer_await(session, offer_sdp)
      assert answer_sdp =~ "H264"
      assert answer_sdp =~ "a=sendonly"
      # non-trickle: the answer already carries the server's ICE candidates
      assert answer_sdp =~ "a=candidate"
    end

    test "registers itself in Cairn.Registry for DELETE lookup" do
      whep_id = "whep_#{System.unique_integer([:positive])}"
      session = start_whep(whep_id)
      assert Cairn.Registry.whereis(whep_id, :whep) == session
    end

    test "a self-owned session survives its starter process exiting" do
      whep_id = "whep_#{System.unique_integer([:positive])}"
      test = self()

      # start the session from a short-lived process, then let it exit
      starter = spawn(fn -> send(test, {:started, Session.start_whep("cam_a", whep_id)}) end)
      starter_ref = Process.monitor(starter)

      # PeerConnection.start_link in the session's init can take a moment
      assert_receive {:started, {:ok, session}}, 5_000
      assert_receive {:DOWN, ^starter_ref, :process, ^starter, _reason}, 1_000

      # the DynamicSupervisor owns the session (no owner monitor), so the
      # starter's exit must not take it down
      assert Process.alive?(session)

      on_exit(fn ->
        if Process.alive?(session),
          do: DynamicSupervisor.terminate_child(CairnWeb.WebRTC.Supervisor, session)
      end)
    end

    @tag :integration
    @tag timeout: 20_000
    test "full non-trickle negotiation reaches :connected" do
      {client, offer_sdp} = nontrickle_offer()
      whep_id = "whep_#{System.unique_integer([:positive])}"
      session = start_whep(whep_id)

      assert {:ok, answer_sdp} = Session.handle_offer_await(session, offer_sdp)

      :ok =
        PeerConnection.set_remote_description(client, %SessionDescription{
          type: :answer,
          sdp: answer_sdp
        })

      assert_receive {:ex_webrtc, ^client, {:connection_state_change, :connected}}, 15_000
    end
  end
end
