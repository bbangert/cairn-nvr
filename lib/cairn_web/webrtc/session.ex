defmodule CairnWeb.WebRTC.Session do
  @moduledoc """
  One process per WebRTC viewer, wrapping an `ExWebRTC.PeerConnection`
  with a sendonly H.264 track.

  Signaling messages flow through the owner (the `webrtc:{camera}`
  channel): the owner calls `handle_offer/2` / `add_ice/2`, and receives
  `{:webrtc_signal, {:ice, json}}` for trickle candidates.

  On `:connected` the session replays the camera's last GOP
  (`Cairn.RTPHub.gop_snapshot/1`) for an instant first frame, then follows
  the live RTP topic. Per the 7.3 spike, ex_webrtc passes seq/timestamps
  through untouched, so replay + live from the same camera stream keeps
  continuity; a seq guard drops the overlap at the boundary.
  """

  use GenServer, restart: :temporary

  require Logger

  alias ExWebRTC.{ICECandidate, MediaStreamTrack, PeerConnection, SessionDescription}

  @spec start(String.t(), pid()) :: DynamicSupervisor.on_start_child()
  def start(camera_id, owner) do
    DynamicSupervisor.start_child(
      CairnWeb.WebRTC.Supervisor,
      {__MODULE__, camera_id: camera_id, owner: owner}
    )
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec handle_offer(pid(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def handle_offer(pid, sdp_offer), do: GenServer.call(pid, {:offer, sdp_offer})

  @spec add_ice(pid(), map()) :: :ok
  def add_ice(pid, candidate_json), do: GenServer.cast(pid, {:ice, candidate_json})

  @impl true
  def init(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)
    owner = Keyword.fetch!(opts, :owner)
    Process.monitor(owner)

    # LAN-only deployment: no STUN/TURN needed (host candidates suffice)
    {:ok, pc} =
      PeerConnection.start_link(
        video_codecs: [:h264],
        ice_servers: Keyword.get(opts, :ice_servers, [])
      )

    track = MediaStreamTrack.new(:video)
    {:ok, _sender} = PeerConnection.add_track(pc, track)

    {:ok,
     %{
       camera_id: camera_id,
       owner: owner,
       pc: pc,
       track_id: track.id,
       subscribed: false,
       replay_last_seq: nil
     }}
  end

  @impl true
  def handle_call({:offer, sdp}, _from, state) do
    with :ok <-
           PeerConnection.set_remote_description(state.pc, %SessionDescription{
             type: :offer,
             sdp: sdp
           }),
         {:ok, answer} <- PeerConnection.create_answer(state.pc),
         :ok <- PeerConnection.set_local_description(state.pc, answer) do
      {:reply, {:ok, answer.sdp}, state}
    else
      error ->
        Logger.warning("webrtc #{state.camera_id}: offer failed: #{inspect(error)}")
        {:reply, {:error, :bad_offer}, state}
    end
  end

  @impl true
  def handle_cast({:ice, candidate_json}, state) do
    # candidate_json is untrusted client input; never let a malformed shape
    # crash the session
    try do
      case PeerConnection.add_ice_candidate(state.pc, ICECandidate.from_json(candidate_json)) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("webrtc: bad ice candidate: #{inspect(reason)}")
      end
    rescue
      _ -> Logger.warning("webrtc: unparseable ice candidate dropped")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_webrtc, pc, {:ice_candidate, candidate}}, %{pc: pc} = state) do
    send(state.owner, {:webrtc_signal, {:ice, ICECandidate.to_json(candidate)}})
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, :connected}}, %{pc: pc} = state) do
    {:noreply, start_streaming(state)}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, terminal}}, %{pc: pc} = state)
      when terminal in [:failed, :closed] do
    {:stop, :normal, state}
  end

  def handle_info({:ex_webrtc, _pc, _msg}, state), do: {:noreply, state}

  def handle_info({:rtp, packet}, state) do
    if replay_overlap?(state, packet) do
      {:noreply, state}
    else
      PeerConnection.send_rtp(state.pc, state.track_id, packet)
      {:noreply, %{state | replay_last_seq: nil}}
    end
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    PeerConnection.close(state.pc)
    :ok
  catch
    _, _ -> :ok
  end

  # subscribe first, then snapshot: no gap; the seq guard drops the overlap
  defp start_streaming(%{subscribed: true} = state), do: state

  defp start_streaming(state) do
    Phoenix.PubSub.subscribe(Cairn.PubSub, Cairn.RTPHub.topic(state.camera_id))
    replay = safe_snapshot(state.camera_id)
    Enum.each(replay, &PeerConnection.send_rtp(state.pc, state.track_id, &1))

    last_seq =
      case List.last(replay) do
        nil -> nil
        packet -> packet.sequence_number
      end

    %{state | subscribed: true, replay_last_seq: last_seq}
  end

  defp safe_snapshot(camera_id) do
    Cairn.RTPHub.gop_snapshot(camera_id)
  catch
    :exit, _ -> []
  end

  # 16-bit serial-number comparison: drop live packets at-or-before the
  # last replayed seq (the subscribe/snapshot overlap window)
  defp replay_overlap?(%{replay_last_seq: nil}, _packet), do: false

  defp replay_overlap?(%{replay_last_seq: last}, packet) do
    diff = Bitwise.band(packet.sequence_number - last, 0xFFFF)
    diff == 0 or diff > 0x8000
  end
end
