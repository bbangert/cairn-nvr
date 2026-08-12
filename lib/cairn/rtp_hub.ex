defmodule Cairn.RTPHub do
  @moduledoc """
  Per-camera RTP fan-out for WebRTC viewers.

  Packets arrive already built via `push_packet/2` from the in-process
  pipeline sink (`Cairn.Pipeline.RTPOut`, which owns sequence/timestamp/
  ssrc); each one is broadcast and folded into the last-GOP replay buffer.
  The buffer resets on every keyframe boundary (see `Cairn.RTP.H264`);
  `{:rtp, packet}` is broadcast on `"camera:{id}:rtp"`. Viewer sessions
  replay `gop_snapshot/1` for an instant first frame, then follow the live
  topic.
  """

  use GenServer

  # bounds memory if a camera emits pathological GOPs (~4096 * ~1200B ≈ 5MB)
  @max_gop_packets 4096

  def start_link(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)
    GenServer.start_link(__MODULE__, opts, name: Cairn.Registry.via(camera_id, :rtp_hub))
  end

  @spec topic(String.t()) :: String.t()
  def topic(camera_id), do: "camera:#{camera_id}:rtp"

  @doc "Packets since the last keyframe boundary, oldest first."
  @spec gop_snapshot(String.t()) :: [ExRTP.Packet.t()]
  def gop_snapshot(camera_id) do
    GenServer.call(Cairn.Registry.via(camera_id, :rtp_hub), :gop_snapshot)
  end

  @doc "Hands an already-built packet to the hub for broadcast + GOP replay."
  @spec push_packet(String.t(), ExRTP.Packet.t()) :: :ok
  def push_packet(camera_id, %ExRTP.Packet{} = packet) do
    GenServer.cast(Cairn.Registry.via(camera_id, :rtp_hub), {:push_packet, packet})
  end

  @impl true
  def init(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)
    {:ok, %{camera_id: camera_id, gop: [], gop_count: 0, gop_ts: nil}}
  end

  @impl true
  def handle_call(:gop_snapshot, _from, state) do
    {:reply, Enum.reverse(state.gop), state}
  end

  @impl true
  def handle_cast({:push_packet, packet}, state) do
    Phoenix.PubSub.broadcast(Cairn.PubSub, topic(state.camera_id), {:rtp, packet})
    {:noreply, update_gop(state, packet)}
  end

  defp update_gop(state, packet) do
    cond do
      Cairn.RTP.H264.keyframe_start?(packet.payload) and packet.timestamp != state.gop_ts ->
        %{state | gop: [packet], gop_count: 1, gop_ts: packet.timestamp}

      state.gop_count >= @max_gop_packets ->
        state

      true ->
        %{state | gop: [packet | state.gop], gop_count: state.gop_count + 1}
    end
  end
end
