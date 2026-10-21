defmodule AppWeb.CacheBodyReader do
  @moduledoc """
  `Plug.Parsers` body reader that keeps the raw body in `conn.assigns.raw_body`, but ONLY for the
  signed dispatch callback (the HMAC is over the exact bytes). Every other request is untouched.
  """
  @path "/api/dispatch/callback"

  def read_body(%Plug.Conn{request_path: @path} = conn, opts) do
    {status, body, conn} = Plug.Conn.read_body(conn, opts)
    prev = conn.assigns[:raw_body] || ""
    {status, body, Plug.Conn.assign(conn, :raw_body, prev <> body)}
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)
end
