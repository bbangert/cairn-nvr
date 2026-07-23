defmodule CairnWeb.UserSocket do
  use Phoenix.Socket

  # Live camera streams (binary fmp4 over the channel)
  channel "camera:*", CairnWeb.StreamChannel
  # WebRTC signaling (sub-second live view)
  channel "webrtc:*", CairnWeb.WebRTCChannel

  # No auth in v1: LAN-trusted deployment (documented in README)
  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
