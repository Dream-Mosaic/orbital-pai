defmodule AppWeb.HealthPlugTest do
  use AppWeb.ConnCase, async: true

  test "GET /healthz answers 200 without auth or a session cookie", %{conn: conn} do
    conn = get(conn, "/healthz")

    assert conn.status == 200
    assert conn.resp_body == "ok"
    assert conn.halted
    refute Map.has_key?(conn.resp_cookies, "_app_key")
  end

  test "other paths pass through to the router", %{conn: conn} do
    conn = get(conn, "/")

    assert redirected_to(conn) == "/login"
  end
end
