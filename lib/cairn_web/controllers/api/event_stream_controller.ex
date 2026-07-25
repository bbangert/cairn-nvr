defmodule CairnWeb.Api.EventStreamController do
  @moduledoc """
  Server-Sent Events feed for Home Assistant.

  Subscribes the request process to the `"events"`, `"cameras:status"` and
  `"system:alerts"` PubSub topics and streams each message as an SSE frame
  (`event: <kind>\\ndata: <json>\\n\\n`) via chunked transfer. A comment
  heartbeat every 20s keeps intermediaries from closing an idle connection;
  HA follows entity availability off this connection.

  The loop exits cleanly when the client disconnects (`chunk/2` returns
  `{:error, _}`) or the connection is closed (`{:plug_conn, :sent}`).
  """

  use CairnWeb, :controller

  require Logger

  alias CairnWeb.Api.EventJSON
  alias CairnWeb.Api.StreamLimiter

  @heartbeat_ms 20_000

  def stream(conn, _params) do
    case StreamLimiter.acquire() do
      :ok ->
        try do
          open_stream(conn)
        after
          StreamLimiter.release()
        end

      :error ->
        conn |> put_status(503) |> json(%{error: "too many stream connections"})
    end
  end

  defp open_stream(conn) do
    Phoenix.PubSub.subscribe(Cairn.PubSub, Cairn.Event.topic())
    Phoenix.PubSub.subscribe(Cairn.PubSub, Cairn.CameraStatus.topic())
    Phoenix.PubSub.subscribe(Cairn.PubSub, Cairn.CameraControl.topic())
    Phoenix.PubSub.subscribe(Cairn.PubSub, Cairn.Retention.topic())

    conn =
      conn
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    case chunk(conn, ": connected\n\n") do
      {:ok, conn} ->
        schedule_heartbeat()
        loop(conn)

      {:error, _reason} ->
        conn
    end
  end

  defp loop(conn) do
    receive do
      :heartbeat ->
        case chunk(conn, ": ping\n\n") do
          {:ok, conn} ->
            schedule_heartbeat()
            loop(conn)

          {:error, _reason} ->
            conn
        end

      {:plug_conn, :sent} ->
        conn

      msg ->
        continue(conn, frame_for(msg))
    end
  end

  # Emit one frame; `:ignore` skips the message, `:error` drops an
  # unencodable frame, both keeping the loop alive. Stop when the socket dies.
  defp continue(conn, :ignore), do: loop(conn)
  defp continue(conn, :error), do: loop(conn)

  defp continue(conn, {:ok, frame}) do
    case chunk(conn, frame) do
      {:ok, conn} -> loop(conn)
      {:error, _reason} -> conn
    end
  end

  @doc """
  Maps a PubSub message to an SSE frame (`{:ok, iodata}`), `:ignore` for
  messages we don't forward, or `:error` for an unencodable payload. Pure —
  exposed for testing the event-lifecycle → frame contract.
  """
  @spec frame_for(term()) :: {:ok, binary()} | :ignore | :error
  def frame_for({kind, %Cairn.Event{} = event})
      when kind in [:event_started, :event_updated, :event_ended] do
    encode_frame(event_name(kind), EventJSON.shape_live(event))
  end

  def frame_for({:camera_status, camera_id, info}) do
    encode_frame("camera_status", %{
      camera_id: camera_id,
      status: Map.get(info, :status),
      probe: safe_probe(Map.get(info, :probe))
    })
  end

  def frame_for({:camera_control, camera_id, control}) do
    encode_frame("camera_control", Map.put(control, :camera_id, camera_id))
  end

  def frame_for({:disk_alert, payload}) do
    encode_frame("disk_alert", payload)
  end

  def frame_for(_other), do: :ignore

  defp encode_frame(event, payload) do
    case Jason.encode(payload) do
      {:ok, json} ->
        {:ok, "event: #{event}\ndata: #{json}\n\n"}

      {:error, reason} ->
        Logger.warning("SSE: dropping #{event} frame, encode failed: #{inspect(reason)}")
        :error
    end
  end

  # `CameraStatus` probe may be `{:error, term}`, which Jason cannot encode.
  defp safe_probe(probe) when is_map(probe), do: probe
  defp safe_probe({:error, reason}), do: %{error: inspect(reason)}
  defp safe_probe(_), do: nil

  defp event_name(:event_started), do: "event_started"
  defp event_name(:event_updated), do: "event_updated"
  defp event_name(:event_ended), do: "event_ended"

  defp schedule_heartbeat, do: Process.send_after(self(), :heartbeat, @heartbeat_ms)
end
