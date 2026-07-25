defmodule CairnWeb.WebRTC.Session do
  @moduledoc """
  One process per WebRTC viewer, wrapping an `ExWebRTC.PeerConnection`
  with a sendonly H.264 track.

  Signaling messages flow through the owner (the `webrtc:{camera}`
  channel): the owner calls `handle_offer/2` / `add_ice/2`, and receives
  `{:webrtc_signal, {:ice, json}}` for trickle candidates.

  On `:connected` the session replays the camera's last GOP
  (`Cairn.RTPHub.gop_snapshot/1`) for an instant first frame, then follows
  the live RTP topic. The session rewrites **sequence numbers** with its
  own monotonic counter on every packet it sends: ffmpeg starts RTP at a
  random seq, and any wrap/regression trips libsrtp's outbound replay
  protection (`Unable to protect RTP: :replay_old` — learned live, revising
  the 7.3 spike verdict). Timestamps pass through untouched. A guard on
  the original camera seq drops duplicate content at the replay/live
  boundary.
  """

  use GenServer, restart: :temporary

  require Logger

  alias ExWebRTC.{ICECandidate, MediaStreamTrack, PeerConnection, SessionDescription}

  # Non-trickle WHEP: reply with the answer once ICE gathering finishes, or
  # after this fallback (LAN host candidates gather in well under this).
  @gather_timeout_ms 2_000
  # Self-owned (WHEP) sessions with no client ever connecting are reaped.
  @connect_deadline_ms 30_000

  @spec start(String.t(), pid()) :: DynamicSupervisor.on_start_child()
  def start(camera_id, owner) do
    DynamicSupervisor.start_child(
      CairnWeb.WebRTC.Supervisor,
      {__MODULE__, camera_id: camera_id, owner: owner}
    )
  end

  @doc """
  Starts a self-owned session for WHEP (HTTP) signaling, registered in
  `Cairn.Registry` under `{whep_id, :whep}` so `DELETE` can find and stop it.
  Unlike `start/2` it has no owner process and survives the request.
  """
  @spec start_whep(String.t(), String.t()) :: DynamicSupervisor.on_start_child()
  def start_whep(camera_id, whep_id) do
    DynamicSupervisor.start_child(
      CairnWeb.WebRTC.Supervisor,
      {__MODULE__, camera_id: camera_id, owner: nil, whep_id: whep_id}
    )
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec handle_offer(pid(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def handle_offer(pid, sdp_offer), do: GenServer.call(pid, {:offer, sdp_offer})

  @doc """
  Non-trickle offer/answer: blocks until ICE gathering completes (or a short
  timeout), returning an answer SDP with candidates already embedded.
  """
  @spec handle_offer_await(pid(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def handle_offer_await(pid, sdp_offer),
    do: GenServer.call(pid, {:offer_await, sdp_offer}, @gather_timeout_ms + 3_000)

  @spec add_ice(pid(), map()) :: :ok
  def add_ice(pid, candidate_json), do: GenServer.cast(pid, {:ice, candidate_json})

  @impl true
  def init(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)
    owner = Keyword.fetch!(opts, :owner)
    whep_id = Keyword.get(opts, :whep_id)

    if is_pid(owner) do
      Process.monitor(owner)
    else
      # self-owned (WHEP): register for DELETE lookup; reap if never connected
      if whep_id, do: Registry.register(Cairn.Registry, {whep_id, :whep}, nil)
      Process.send_after(self(), :connect_deadline, @connect_deadline_ms)
    end

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
       replay_last_seq: nil,
       out_seq: 0,
       await_from: nil,
       gather_timer: nil
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

  # Non-trickle: set up the answer, then defer the reply until gathering ends.
  def handle_call({:offer_await, sdp}, from, state) do
    with :ok <-
           PeerConnection.set_remote_description(state.pc, %SessionDescription{
             type: :offer,
             sdp: sdp
           }),
         {:ok, answer} <- PeerConnection.create_answer(state.pc),
         :ok <- PeerConnection.set_local_description(state.pc, answer) do
      timer = Process.send_after(self(), :gather_timeout, @gather_timeout_ms)
      {:noreply, %{state | await_from: from, gather_timer: timer}}
    else
      error ->
        Logger.warning("webrtc #{state.camera_id}: whep offer failed: #{inspect(error)}")
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
    # trickle only applies to owner-driven (browser) sessions; WHEP embeds
    # candidates in the answer instead
    if is_pid(state.owner) do
      send(state.owner, {:webrtc_signal, {:ice, ICECandidate.to_json(candidate)}})
    end

    {:noreply, state}
  end

  # Non-trickle answer is ready once gathering completes.
  def handle_info(
        {:ex_webrtc, pc, {:ice_gathering_state_change, :complete}},
        %{pc: pc, await_from: from} = state
      )
      when not is_nil(from) do
    {:noreply, reply_answer(state)}
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
      {:noreply, send_packet(%{state | replay_last_seq: nil}, packet)}
    end
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state) do
    {:stop, :normal, state}
  end

  # Gathering didn't finish in time: answer with whatever we have (LAN host
  # candidates are effectively immediate, so this rarely fires).
  def handle_info(:gather_timeout, %{await_from: from} = state) when not is_nil(from) do
    {:noreply, reply_answer(state)}
  end

  # WHEP session whose client never connected: reap it.
  def handle_info(:connect_deadline, %{subscribed: false} = state) do
    Logger.info("webrtc #{state.camera_id}: whep session idle (never connected), stopping")
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

  # Reply to the deferred non-trickle offer with the fully-gathered answer.
  defp reply_answer(state) do
    if state.gather_timer, do: Process.cancel_timer(state.gather_timer)
    answer = PeerConnection.get_local_description(state.pc)
    GenServer.reply(state.await_from, {:ok, answer.sdp})
    %{state | await_from: nil, gather_timer: nil}
  end

  # subscribe first, then snapshot: no gap; the seq guard drops the overlap
  defp start_streaming(%{subscribed: true} = state), do: state

  defp start_streaming(state) do
    Phoenix.PubSub.subscribe(Cairn.PubSub, Cairn.RTPHub.topic(state.camera_id))
    replay = safe_snapshot(state.camera_id)
    state = Enum.reduce(replay, state, &send_packet(&2, &1))

    last_seq =
      case List.last(replay) do
        nil -> nil
        packet -> packet.sequence_number
      end

    %{state | subscribed: true, replay_last_seq: last_seq}
  end

  # our own outbound seq keeps libsrtp's replay window strictly monotonic
  defp send_packet(state, packet) do
    packet = %{packet | sequence_number: rem(state.out_seq, 65_536)}
    PeerConnection.send_rtp(state.pc, state.track_id, packet)
    %{state | out_seq: state.out_seq + 1}
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
