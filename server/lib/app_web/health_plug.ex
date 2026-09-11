defmodule AppWeb.HealthPlug do
  @moduledoc """
  Answers `GET /healthz` with a bare 200 for the container healthcheck (docker-compose.yml).

  Mounted first in `AppWeb.Endpoint` so a probe skips request logging, the session and auth —
  it runs every 30s, and would otherwise write a log line and mint a cookie each time.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: "/healthz"} = conn, _opts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
    |> halt()
  end

  def call(conn, _opts), do: conn
end
