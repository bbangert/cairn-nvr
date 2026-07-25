defmodule CairnWeb.Plugs.ApiAuth do
  @moduledoc """
  Token authentication for the `/api` (Home Assistant) surface.

  Reads the configured `integrations.token` (see `Cairn.Config`) and compares it
  against the request's `Authorization: Bearer <token>` header, or an
  `?access_token=<token>` query param (used for media URLs HA hands to players
  that cannot set headers). The comparison is constant-time.

  When no token is configured the integration is disabled and every request is
  rejected with 401 — the browser's cookie-authed `/`, `/media`, `/hls` surfaces
  are untouched by this plug.
  """

  import Plug.Conn

  alias Cairn.Config.Server

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    # `:token_fun` is a test seam; production always uses the configured token.
    token_fun = Keyword.get(opts, :token_fun, &Server.ha_token/0)

    with configured when is_binary(configured) <- token_fun.(),
         presented when is_binary(presented) <- presented_token(conn),
         true <- Plug.Crypto.secure_compare(presented, configured) do
      conn
    else
      _ -> unauthorized(conn)
    end
  end

  defp presented_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> fetch_query_params(conn).query_params["access_token"]
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end
end
