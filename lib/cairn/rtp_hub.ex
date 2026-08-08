defmodule Cairn.RTPHub do
  @moduledoc """
  Per-camera RTP fan-out for WebRTC viewers.

  Ingests RTP packets by one of two paths, then runs the same broadcast +
  last-GOP-replay update for both:

    * classic stack — owns a `gen_udp` socket receiving ffmpeg's third output
      and decodes each datagram (`ExRTP.Packet.decode/1`). Opened when a
      `:port` option is given.
    * membrane stack — no socket (`port: nil`); packets arrive already built
      via `push_packet/2` from the in-process pipeline sink.

  Both stacks run concurrently during migration, so the socket path must keep
  working unchanged. The replay buffer resets on every keyframe boundary (see
  `Cairn.RTP.H264`); `{:rtp, packet}` is broadcast on `"camera:{id}:rtp"`.
  Viewer sessions replay `gop_snapshot/1` for an instant first frame, then
  follow the live topic.
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

  @doc """
  Hands an already-built packet to the in-process (membrane) ingest path.

  Runs the identical broadcast + GOP update the socket path runs on a decoded
  datagram; the caller (`Cairn.Pipeline.RTPOut`) owns sequence/timestamp/ssrc.
  """
  @spec push_packet(String.t(), ExRTP.Packet.t()) :: :ok
  def push_packet(camera_id, %ExRTP.Packet{} = packet) do
    GenServer.cast(Cairn.Registry.via(camera_id, :rtp_hub), {:push_packet, packet})
  end

  @impl true
  def init(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)
    state = %{camera_id: camera_id, socket: nil, gop: [], gop_count: 0, gop_ts: nil}

    # `port: nil` (or absent) selects the socketless in-process path; classic
    # callers pass an integer port and must still get a bound socket.
    case Keyword.get(opts, :port) do
      nil ->
        {:ok, state}

      port ->
        attempts = Keyword.get(opts, :open_attempts, @open_attempts)

        case open(port, attempts) do
          {:ok, socket} -> {:ok, %{state | socket: socket}}
          {:error, reason} -> {:stop, {:udp_open_failed, port, reason}}
        end
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
  def handle_cast({:push_packet, packet}, state) do
    {:noreply, ingest(state, packet)}
  end

  @impl true
  def handle_info({:udp, socket, _ip, _port, data}, %{socket: socket} = state) do
    case ExRTP.Packet.decode(data) do
      {:ok, packet} -> {:noreply, ingest(state, packet)}
      {:error, _reason} -> {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Shared tail of both ingest paths: fan out, then fold into the replay buffer.
  defp ingest(state, packet) do
    Phoenix.PubSub.broadcast(Cairn.PubSub, topic(state.camera_id), {:rtp, packet})
    update_gop(state, packet)
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
