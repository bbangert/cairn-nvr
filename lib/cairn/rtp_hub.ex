defmodule Cairn.RTPHub do
  @moduledoc """
  Per-camera RTP fan-out for WebRTC viewers.

  Owns the `gen_udp` socket receiving ffmpeg's third output, decodes each
  RTP packet (`ExRTP.Packet`), maintains a last-GOP replay buffer (reset on
  every keyframe boundary, see `Cairn.RTP.H264`), and broadcasts
  `{:rtp, packet}` on `"camera:{id}:rtp"`. Viewer sessions replay
  `gop_snapshot/1` for an instant first frame, then follow the live topic.
  """

  use GenServer

  require Logger

  # bounds memory if a camera emits pathological GOPs (~4096 * ~1200B ≈ 5MB)
  @max_gop_packets 4096

  # UDP ports are positional (`Cairn.UDPPorts`), so a reload that reorders
  # cameras hands a port to a successor while the predecessor's socket fd is
  # still being released — a beat after the registry already agrees it is gone
  # (`Cairn.Registry.await_unregistered/3`). Bounded (25 ms * 20 = 500 ms) and
  # only for `:eaddrinuse`: a genuine conflict with a foreign listener must
  # still surface as a start failure rather than be waited out silently.
  @open_retry_ms 25
  @open_attempts 20

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

  @impl true
  def init(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)
    port = Keyword.fetch!(opts, :port)
    attempts = Keyword.get(opts, :open_attempts, @open_attempts)

    case open(port, attempts) do
      {:ok, socket} ->
        {:ok, %{camera_id: camera_id, socket: socket, gop: [], gop_count: 0, gop_ts: nil}}

      {:error, reason} ->
        {:stop, {:udp_open_failed, port, reason}}
    end
  end

  defp open(port, attempts, waited_ms \\ 0) do
    case :gen_udp.open(port, [:binary, active: true, ip: {127, 0, 0, 1}, recbuf: 1_048_576]) do
      {:ok, socket} ->
        if waited_ms > 0 do
          Logger.info("rtp hub port #{port} freed after #{waited_ms}ms — predecessor lingered")
        end

        {:ok, socket}

      {:error, :eaddrinuse} when attempts > 1 ->
        Process.sleep(@open_retry_ms)
        open(port, attempts - 1, waited_ms + @open_retry_ms)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def handle_call(:gop_snapshot, _from, state) do
    {:reply, Enum.reverse(state.gop), state}
  end

  @impl true
  def handle_info({:udp, socket, _ip, _port, data}, %{socket: socket} = state) do
    case ExRTP.Packet.decode(data) do
      {:ok, packet} ->
        Phoenix.PubSub.broadcast(
          Cairn.PubSub,
          topic(state.camera_id),
          {:rtp, packet}
        )

        {:noreply, update_gop(state, packet)}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

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
