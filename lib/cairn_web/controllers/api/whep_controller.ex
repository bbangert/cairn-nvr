defmodule CairnWeb.Api.WhepController do
  @moduledoc """
  WHEP-style WebRTC endpoint for Home Assistant live streams.

  `POST /api/cameras/:id/webrtc` takes an offer SDP (raw `application/sdp` or
  JSON `{"sdp": ...}`), starts a self-owned `WebRTC.Session`, and returns `201`
  with a non-trickle answer SDP plus a `Location` resource URL. `DELETE` on that
  resource tears the session down. Concurrency is capped by
  `WebRTC.Supervisor` (`max_children`) → `503` when full.
  """

  use CairnWeb, :controller

  require Logger

  alias Cairn.Config.Server
  alias CairnWeb.WebRTC.Session
  alias CairnWeb.WebRTC.Supervisor

  # SDP offers are a few KB; cap the body to shrink the request-body DoS surface.
  @max_sdp_bytes 65_536

  def create(conn, %{"id" => camera_id} = params) do
    with {:ok, _cam} <- camera(camera_id),
         {:ok, offer} <- read_offer(conn, params) do
      negotiate(conn, camera_id, offer)
    else
      :unknown_camera -> send_error(conn, 404, "unknown camera")
      :no_offer -> send_error(conn, 400, "missing sdp offer")
      :too_large -> send_error(conn, 413, "sdp offer too large")
    end
  end

  # The supervisor, not the registry, decides whether this DELETE tore anything
  # down. A Registry entry outlives its process briefly — unregistration rides
  # the async DOWN/EXIT the registry partition sends itself — so a lookup right
  # after a teardown still hands back the dead pid, and a repeat DELETE would
  # answer 204 for a session that is already gone. `terminate_child/2` removes
  # the child from supervisor state in the same `handle_call` return that
  # replies, so a repeat DELETE is deterministically `{:error, :not_found}`.
  #
  # That is not total precision. A DELETE racing the session's *own* exit (the
  # connect-deadline reap, a peer connection going `:failed`/`:closed`) can be
  # dequeued ahead of the child's EXIT: `monitor_child/1`'s `receive ... after 0`
  # consumes the queued EXIT, `{:error, :normal}` is dropped for a `:temporary`
  # child, and the reply is still `:ok` → 204 for a session already gone.
  # Defensible for DELETE — the resource is gone either way — but it is a 204,
  # not a 404.
  def delete(conn, %{"resource_id" => whep_id}) do
    with pid when is_pid(pid) <- Cairn.Registry.whereis(whep_id, :whep),
         :ok <- DynamicSupervisor.terminate_child(Supervisor, pid) do
      send_resp(conn, 204, "")
    else
      _ -> send_error(conn, 404, "unknown session")
    end
  end

  defp negotiate(conn, camera_id, offer) do
    whep_id = generate_id()

    case Session.start_whep(camera_id, whep_id) do
      {:ok, session} ->
        answer_or_teardown(conn, session, whep_id, offer)

      {:error, :max_children} ->
        send_error(conn, 503, "too many active streams")

      {:error, reason} ->
        Logger.warning("whep: session start failed for #{camera_id}: #{inspect(reason)}")
        send_error(conn, 500, "session failed")
    end
  end

  defp answer_or_teardown(conn, session, whep_id, offer) do
    case negotiate_answer(session, offer) do
      {:ok, answer} ->
        conn
        |> put_resp_header("location", "/api/webrtc/#{whep_id}")
        |> put_resp_content_type("application/sdp")
        |> send_resp(201, answer)

      {:error, :bad_offer} ->
        DynamicSupervisor.terminate_child(Supervisor, session)
        send_error(conn, 400, "bad offer")

      {:error, :timeout} ->
        # the session stalled negotiating; tear it down so it doesn't sit
        # until the connect-deadline reaper and fill max_children
        DynamicSupervisor.terminate_child(Supervisor, session)
        send_error(conn, 503, "stream negotiation timed out")
    end
  end

  # `handle_offer_await/2` is a GenServer.call; a stalled negotiation raises an
  # exit we translate into a clean 503 (JSON) rather than a bare 500.
  defp negotiate_answer(session, offer) do
    Session.handle_offer_await(session, offer)
  catch
    :exit, _reason -> {:error, :timeout}
  end

  defp camera(camera_id) do
    case Server.camera(camera_id) do
      {:ok, cam} -> {:ok, cam}
      :error -> :unknown_camera
    end
  end

  # JSON `{"sdp": ...}` first (already parsed into params), else a raw
  # `application/sdp` body (passed through unparsed by Plug.Parsers).
  defp read_offer(conn, params) do
    case params["sdp"] do
      sdp when is_binary(sdp) and byte_size(sdp) > @max_sdp_bytes ->
        :too_large

      sdp when is_binary(sdp) and sdp != "" ->
        {:ok, sdp}

      _ ->
        case read_body(conn, length: @max_sdp_bytes) do
          {:ok, body, _conn} when byte_size(body) > 0 -> {:ok, body}
          # an offer larger than the cap comes back as {:more, _, _}: it was
          # provided, just too big — distinct from a missing body (413 vs 400)
          {:more, _partial, _conn} -> :too_large
          _ -> :no_offer
        end
    end
  end

  defp generate_id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  defp send_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
