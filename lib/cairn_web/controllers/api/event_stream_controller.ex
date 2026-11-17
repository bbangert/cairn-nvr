defmodule CairnWeb.Api.EventStreamController do
  @moduledoc """
  Server-Sent Events feed for Home Assistant.

  Subscribes the request process to the `"events"` (event, artifact *and*
  track lifecycle), `"cameras:status"`, `"cameras:control"` and
  `"system:alerts"` PubSub topics and streams each message as an SSE frame
  (`event: <kind>\\ndata: <json>\\n\\n`) via chunked transfer. A comment
  heartbeat every 20s keeps intermediaries from closing an idle connection;
  HA follows entity availability off this connection.

  The stream ends when:

    * a write fails (`chunk/2` returns `{:error, _}`), so a client that has
      gone is noticed at the next frame or, at the latest, the next heartbeat;
    * the connection process receives an exit signal — the listener shutting
      down, or the `CairnWeb.Api.StreamLimiter` registry holding its slot
      going down;
    * `integrations.token` is other than the token the request was
      authenticated with (rotated or removed). Checked on a config change
      (`Cairn.Config.topic/0`), straight after subscribing (a mismatch answers
      401 instead of opening the stream) and before every frame and heartbeat,
      so a stream whose writes go through outlives its token by at most one
      heartbeat interval even when nothing is broadcast;
    * more than `@max_backlog` messages are waiting in the mailbox, i.e. the
      client reads slower than events arrive. It reconnects and re-reads state.

  While a write is blocked on a client that reads nothing, nothing else in
  the loop runs — no token check, no backlog bound, no exit signal — until
  the transport's send timeout (30 s by default) fails the write and ends the
  stream. Bandit's adapter gives a plug no handle on the socket to cut that
  short.

  Over HTTP/1 the connection closes with the stream, and with that 401
  (`connection: close`).
  """

  use CairnWeb, :controller

  require Logger

  alias Cairn.Config.Server
  alias CairnWeb.Api.EventJSON
  alias CairnWeb.Api.StreamLimiter

  @heartbeat_ms 20_000
  # A write to a client that reads nothing is bounded by the transport's
  # send timeout; one that reads just fast enough to stay under it is not,
  # and PubSub keeps filling the mailbox meanwhile.
  @max_backlog 1_000

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
    Server.subscribe()

    # After the subscribe: a reload that landed since `ApiAuth` ran has no
    # broadcast left for the loop to see.
    if authorized?(conn) do
      conn =
        conn
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("x-accel-buffering", "no")
        |> close_after_stream()
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      case chunk(conn, ": connected\n\n") do
        {:ok, conn} ->
          schedule_heartbeat()
          loop(conn)

        {:error, _reason} ->
          conn
      end
    else
      conn |> close_after_stream() |> put_status(401) |> json(%{error: "unauthorized"})
    end
  end

  defp loop(conn) do
    if backlogged?() do
      Logger.warning("SSE: client reads too slowly, closing the stream")
      conn
    else
      receive do
        :heartbeat ->
          case write(conn, ": ping\n\n") do
            {:ok, conn} ->
              schedule_heartbeat()
              loop(conn)

            {:error, _reason} ->
              conn
          end

        # Ends an idle stream promptly instead of at the next heartbeat. Any
        # server's diff: the re-check reads the singleton's snapshot, not the
        # diff, so another server's broadcast only costs a term read.
        {:config_changed, _diff} ->
          if authorized?(conn), do: loop(conn), else: conn

        # The handler traps exits, so its supervisor's shutdown arrives here
        # and would otherwise wait out the listener's shutdown timeout before
        # a kill. Put back, not consumed: the gen_server underneath has to see
        # its parent's exit to terminate; Bandit ignores any other.
        {:EXIT, _pid, _reason} = signal ->
          send(self(), signal)
          conn

        msg ->
          continue(conn, frame_for(msg))
      end
    end
  end

  # The subscriptions, and whatever they queued, belong to this process, and
  # an HTTP/1 connection's process goes on to serve its next request: a stream
  # that ends, or is refused once subscribed, with the socket still open must
  # take the connection with it, or a reconnect over keep-alive would
  # subscribe a second time. An HTTP/2 stream runs in a process of its own,
  # and forbids the header.
  defp close_after_stream(conn) do
    if get_http_protocol(conn) in [:"HTTP/1.0", :"HTTP/1.1"],
      do: put_resp_header(conn, "connection", "close"),
      else: conn
  end

  defp backlogged? do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    len > @max_backlog
  end

  # Before every write, not only on `config_changed`: the server publishes a
  # new snapshot before it broadcasts, and a restarted one broadcasts nothing.
  defp write(conn, data) do
    if authorized?(conn), do: chunk(conn, data), else: {:error, :unauthorized}
  end

  # The snapshot rather than `Server.ha_token/0`: a call would block the
  # stream for as long as a save holds the server. It leads `get/1` during an
  # apply, so a stream can end slightly before the new token is answered.
  defp authorized?(conn) do
    case Server.snapshot() do
      %Cairn.Config{ha_token: token} when is_binary(token) ->
        token == conn.private[:cairn_api_token]

      _ ->
        false
    end
  end

  # Emit one frame; `:ignore` skips the message, `:error` drops an
  # unencodable frame, both keeping the loop alive. Stop when the socket dies.
  defp continue(conn, :ignore), do: loop(conn)
  defp continue(conn, :error), do: loop(conn)

  defp continue(conn, {:ok, frame}) do
    case write(conn, frame) do
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

  def frame_for({kind, %Cairn.EventArtifact{} = artifact})
      when kind in [
             :event_clip_ready,
             :event_clip_failed,
             :event_snapshot_ready,
             :event_snapshot_failed
           ] do
    encode_frame(artifact_name(kind), EventJSON.shape_artifact(kind, artifact))
  end

  def frame_for({kind, %Cairn.Track{} = track})
      when kind in [:track_started, :track_updated, :track_ended] do
    encode_frame(track_name(kind), EventJSON.shape_track(track))
  end

  def frame_for({kind, %Cairn.PresenceEvent{} = presence})
      when kind in [:presence_started, :presence_cleared] do
    encode_frame(Atom.to_string(kind), EventJSON.shape_presence(kind, presence))
  end

  def frame_for({:camera_status, camera_id, info}) do
    encode_frame("camera_status", %{
      camera_id: camera_id,
      status: Map.get(info, :status),
      probe: safe_probe(Map.get(info, :probe)),
      plugin_status: Map.get(info, :plugin_status)
    })
  end

  def frame_for({:camera_control, camera_id, control}) do
    encode_frame("camera_control", Map.put(control, :camera_id, camera_id))
  end

  def frame_for({:disk_alert, payload}) do
    encode_frame("disk_alert", payload)
  end

  # `{:plug_conn, :sent}` lands here too: Bandit sends it to the request
  # process as the response starts, so it is no sign that the stream ended.
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

  defp track_name(:track_started), do: "track_started"
  defp track_name(:track_updated), do: "track_updated"
  defp track_name(:track_ended), do: "track_ended"

  defp artifact_name(:event_clip_ready), do: "event_clip_ready"
  defp artifact_name(:event_clip_failed), do: "event_clip_failed"
  defp artifact_name(:event_snapshot_ready), do: "event_snapshot_ready"
  defp artifact_name(:event_snapshot_failed), do: "event_snapshot_failed"

  defp schedule_heartbeat, do: Process.send_after(self(), :heartbeat, @heartbeat_ms)
end
