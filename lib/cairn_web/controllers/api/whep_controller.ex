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

  def create(conn, %{"id" => camera_id} = params) do
    with {:ok, _cam} <- camera(camera_id),
         {:ok, offer} <- read_offer(conn, params) do
      negotiate(conn, camera_id, offer)
    else
      :unknown_camera -> send_error(conn, 404, "unknown camera")
      :no_offer -> send_error(conn, 400, "missing sdp offer")
    end
  end

  def delete(conn, %{"resource_id" => whep_id}) do
    case Cairn.Registry.whereis(whep_id, :whep) do
      nil ->
        send_error(conn, 404, "unknown session")

      pid ->
        DynamicSupervisor.terminate_child(Supervisor, pid)
        send_resp(conn, 204, "")
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
      sdp when is_binary(sdp) and sdp != "" ->
        {:ok, sdp}

      _ ->
        case read_body(conn) do
          {:ok, body, _conn} when byte_size(body) > 0 -> {:ok, body}
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
