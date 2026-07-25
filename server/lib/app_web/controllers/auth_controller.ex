defmodule AppWeb.AuthController do
  @moduledoc """
  Google sign-in (identity), distinct from connection OAuth. `login/2` starts the consent for
  `openid email` and tags the session flow `:login`; the shared `/auth/google/callback` (in
  GoogleAuthController) branches on that flow to log the user in via `App.Users.upsert_allowed/1`.
  """
  use AppWeb, :controller

  alias App.Google.OAuth
  alias AppWeb.UserAuth

  def login_page(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: ~p"/")
    else
      render(conn, :login, current_user: nil)
    end
  end

  def login(conn, _params) do
    state = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    conn
    |> put_session(:google_oauth_state, state)
    |> put_session(:google_oauth_flow, "login")
    |> redirect(external: OAuth.authorize_url(state, ["openid", "email"]))
  end

  def logout(conn, _params), do: UserAuth.log_out_user(conn)
end
