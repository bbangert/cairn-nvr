defmodule CairnWeb.Api.ApiAuthTest do
  # Reads the global Config.Server token from the test fixture; no DB writes.
  use CairnWeb.ConnCase, async: true

  @token "test-ha-token"

  test "401 without any token", %{conn: conn} do
    conn = get(conn, "/api/cameras")
    assert json_response(conn, 401)["error"] == "unauthorized"
  end

  test "401 with a wrong bearer token", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer wrong")
      |> get("/api/cameras")

    assert json_response(conn, 401)
  end

  test "200 with the correct bearer token", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get("/api/cameras")

    assert json_response(conn, 200)
  end

  test "200 with the access_token query param", %{conn: conn} do
    conn = get(conn, "/api/cameras?access_token=#{@token}")
    assert json_response(conn, 200)
  end

  test "browser pages remain reachable without the token", %{conn: conn} do
    # sanity: the token gate is scoped to /api, not the whole app
    conn = get(conn, "/media/events/does-not-exist")
    assert response(conn, 404)
  end

  describe "integration disabled (no token configured)" do
    test "rejects even a well-formed request with 401", %{conn: conn} do
      opts = CairnWeb.Plugs.ApiAuth.init(token_fun: fn -> nil end)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@token}")
        |> Map.put(:path_info, ["api", "cameras"])
        |> CairnWeb.Plugs.ApiAuth.call(opts)

      assert conn.status == 401
      assert conn.halted
    end
  end
end
