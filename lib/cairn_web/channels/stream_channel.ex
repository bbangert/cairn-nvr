defmodule CairnWeb.StreamChannel do
  @moduledoc """
  Live MSE transport: one channel per viewer per camera (`"camera:{id}"`).

  Join replies with the RFC 6381 codec string; the server then pushes the
  init segment and every live fragment as binary frames (`"init"` /
  `"segment"` events). On an ffmpeg session restart a fresh init segment is
  pushed — the client resets its MediaSource.

  Slow-consumer policy: before every push the transport pid's
  `message_queue_len` is checked; above the high-water mark the channel
  stops with `:slow_consumer` and the client reconnects fresh at the live
  edge. The channel never buffers fragments itself.
  """

  use Phoenix.Channel

  alias Cairn.RingBuffer

  @high_water 8

  @impl true
  def join("camera:" <> camera_id, _params, socket) do
    # 3 fragments (~6s) of backlog lets the client start with a cushion
    # instead of stalling at the live edge until the next fragment lands.
    #
    # `fetch_recent_safe/2` and not `fetch_recent/2`: the whereis below can hand
    # back a ring the registry has not reaped yet, and a via-tuple call on a
    # dead pid exits — this `else` matches values, so the join would crash
    # instead of answering "camera offline".
    with {:ok, _cam} <- Cairn.Config.Server.camera(camera_id),
         ring when is_pid(ring) <- Cairn.Registry.whereis(camera_id, :ring_buffer),
         {:ok, %{codec: codec} = data} <- RingBuffer.fetch_recent_safe(camera_id, 3) do
      Phoenix.PubSub.subscribe(Cairn.PubSub, RingBuffer.topic(camera_id))
      send(self(), {:after_join, data})
      {:ok, %{codec: codec}, assign(socket, :camera_id, camera_id)}
    else
      :error -> {:error, %{reason: "unknown camera"}}
      nil -> {:error, %{reason: "camera offline"}}
    end
  end

  @impl true
  def handle_info({:after_join, %{init: init, fragments: fragments}}, socket) do
    if is_binary(init), do: push(socket, "init", {:binary, init})
    Enum.each(fragments, &push(socket, "segment", {:binary, &1.data}))
    {:noreply, socket}
  end

  def handle_info({:fragment, frag}, socket) do
    if slow_consumer?(socket) do
      {:stop, {:shutdown, :slow_consumer}, socket}
    else
      push(socket, "segment", {:binary, frag.data})
      {:noreply, socket}
    end
  end

  def handle_info({:init_segment, _meta}, socket) do
    # a new session's init: pts restart, client must reset its MediaSource
    case RingBuffer.fetch_recent_safe(socket.assigns.camera_id, 0) do
      {:ok, %{init: init}} when is_binary(init) -> push(socket, "init", {:binary, init})
      _ -> :noop
    end

    {:noreply, socket}
  end

  defp slow_consumer?(socket) do
    case Process.info(socket.transport_pid, :message_queue_len) do
      {:message_queue_len, len} -> len > @high_water
      nil -> true
    end
  end
end
