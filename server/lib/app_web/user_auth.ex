defmodule AppWeb.UserAuth do
  @moduledoc """
  Session-based auth for the two-user app. Plugs: `fetch_current_user/2` (assigns
  `:current_user` from the session) and `require_user/2` (redirect to /login if absent). An
  `on_mount` of the same name assigns `:current_user` in LiveViews. Socket auth uses a
  `Phoenix.Token` carrying the user id (so the voice socket can't be spoofed).
  """
  import Plug.Conn
  import Phoenix.Controller

  alias App.Users
  alias Phoenix.Token

  @socket_salt "voice socket user"
  @max_age 60 * 60 * 24 * 30

  def init(opts), do: opts
  def call(conn, :fetch_current_user), do: fetch_current_user(conn, [])
  def call(conn, _), do: require_user(conn, [])

  def log_in_user(conn, user) do
    conn
    |> renew_session()
    |> put_session(:user_id, user.id)
  end

  def log_out_user(conn) do
    conn |> renew_session() |> redirect(to: "/login")
  end

  def fetch_current_user(conn, _opts) do
    user = conn |> get_session(:user_id) |> load_user()
    assign(conn, :current_user, user)
  end

  def require_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> store_return_to()
      |> put_flash(:error, "Please sign in.")
      |> redirect(to: "/login")
      |> halt()
    end
  end

  # Remember what the signed-out request was actually asking for, so signing in resumes it
  # instead of dumping the user on "/". This is what makes the native app's connector flow
  # survive an unauthenticated browser: the app opens `/auth/google/connect?...`, and without
  # this the grant it encoded in that URL is silently discarded at the login bounce -- the user
  # signs in, lands home, and nothing they asked for has happened.
  #
  # `current_path/1` reads the path and query off the request being refused, never off a param,
  # so the stored value is always internal to this app and cannot be aimed at another host.
  # GET only: a replayed POST is not a safe thing to resume on the user's behalf.
  #
  # `log_in_user/2` renews the session, which clears this key -- so it is consumed exactly once
  # and cannot leak into a later, unrelated sign-in.
  defp store_return_to(%Plug.Conn{method: "GET"} = conn),
    do: put_session(conn, :user_return_to, current_path(conn))

  defp store_return_to(conn), do: conn

  def on_mount(:default, _params, session, socket) do
    user = session |> Map.get("user_id") |> load_user()

    if user do
      {:cont, Phoenix.Component.assign(socket, :current_user, user)}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end

  @doc "A signed token binding a socket to a user id (embedded in the page, sent on connect)."
  def socket_token(user_id), do: Token.sign(AppWeb.Endpoint, @socket_salt, user_id)

  def verify_socket_token(token) when is_binary(token) do
    case Token.verify(AppWeb.Endpoint, @socket_salt, token, max_age: @max_age) do
      {:ok, user_id} -> {:ok, user_id}
      {:error, _} -> :error
    end
  end

  def verify_socket_token(_), do: :error

  @doc "Verify a socket token AND confirm the user still exists + is allowlisted. Returns the user or nil."
  def authenticate_socket(token) do
    case verify_socket_token(token) do
      {:ok, user_id} -> load_user(user_id)
      :error -> nil
    end
  end

  # Resolve a session/token user id to a live, still-allowlisted user (or nil). Re-checking the
  # allowlist here means removing an email from :allowed_users evicts that user on their next
  # request/reconnect, and a deleted users row locks out both the web and the voice socket.
  defp load_user(nil), do: nil

  defp load_user(id) do
    case Users.get(id) do
      nil -> nil
      user -> if Users.allowed?(user.email), do: user, else: nil
    end
  end

  defp renew_session(conn) do
    conn |> configure_session(renew: true) |> clear_session()
  end
end
