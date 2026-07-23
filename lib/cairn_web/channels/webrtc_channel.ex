defmodule CairnWeb.WebRTCChannel do
  @moduledoc """
  Signaling for the sub-second live view (`"webrtc:{camera}"`).

  Client -> server events: `"offer"` (`%{"sdp" => sdp}`, replies with the
  answer sdp) and `"ice"` (`%{"candidate" => json}`); server -> client:
  `"ice"` pushes with trickle candidates. Media never touches the channel —
  it flows PeerConnection-to-browser.
  """

  use Phoenix.Channel

  alias CairnWeb.WebRTC.Session

  @impl true
  def join("webrtc:" <> camera_id, _params, socket) do
    with {:ok, _cam} <- Cairn.Config.Server.camera(camera_id),
         {:ok, session} <- Session.start(camera_id, self()) do
      {:ok, assign(socket, :session, session)}
    else
      :error -> {:error, %{reason: "unknown camera"}}
      {:error, _} -> {:error, %{reason: "session failed"}}
    end
  end

  @impl true
  def handle_in("offer", %{"sdp" => sdp}, socket) do
    case Session.handle_offer(socket.assigns.session, sdp) do
      {:ok, answer_sdp} -> {:reply, {:ok, %{sdp: answer_sdp}}, socket}
      {:error, _} -> {:reply, {:error, %{reason: "bad offer"}}, socket}
    end
  end

  def handle_in("ice", %{"candidate" => candidate}, socket) do
    Session.add_ice(socket.assigns.session, candidate)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:webrtc_signal, {:ice, candidate_json}}, socket) do
    push(socket, "ice", %{candidate: candidate_json})
    {:noreply, socket}
  end
end
