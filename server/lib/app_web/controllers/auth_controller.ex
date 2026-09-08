defmodule AppWeb.AuthController do
  @moduledoc """
  Authentik sign-in (identity), distinct from Google connectors. `login/2` starts the Authentik
  consent (via `App.Auth.Oidc`) and stores a CSRF `state` under `:oidc_state` — a session key
  that belongs exclusively to this flow, never `:google_oauth_state`/`:google_oauth_flow` (those
  stay `GoogleAuthController`'s, for connectors). `callback/2` verifies the state, exchanges the
  code, reads the login claims, and resolves the row via `App.Users.upsert_from_oidc/1`.
  """
  use AppWeb, :controller
  require Logger

  alias App.Auth.Oidc
  alias App.Users
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

    case Oidc.authorize_url(state) do
      {:ok, url} ->
        conn
        |> put_session(:oidc_state, state)
        |> redirect(external: url)

      {:error, reason} ->
        Logger.warning("[auth] could not build the Authentik authorize URL: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Sign-in is unavailable right now. Please try again shortly.")
        |> redirect(to: ~p"/login")
    end
  end

  def callback(conn, %{"state" => state} = params) do
    expected = get_session(conn, :oidc_state)

    cond do
      is_nil(expected) or state != expected ->
        login_failed(conn, "Sign-in failed (state mismatch). Please try again.")

      params["error"] ->
        login_failed(conn, "Sign-in cancelled.")

      true ->
        handle_code(conn, params["code"])
    end
  end

  def callback(conn, _params), do: login_failed(conn, "Sign-in failed.")

  defp handle_code(conn, nil), do: login_failed(conn, "Sign-in failed (no code).")

  defp handle_code(conn, code) do
    with {:ok, %{id_token: id_token}} <- Oidc.exchange_code(code),
         {:ok, claims} <- Oidc.claims_from_id_token(id_token),
         {:ok, user} <- Users.upsert_from_oidc(claims) do
      # Read BEFORE log_in_user/2, which renews the session and so CLEARS everything stored in
      # it -- this key included. Without this, a signed-out browser sent here by
      # `UserAuth.require_user/2` loses whatever it was originally asking for: for a connector
      # grant link that is the entire request, silently discarded.
      return_to = get_session(conn, :user_return_to) || ~p"/"

      conn
      |> UserAuth.log_in_user(user)
      |> put_flash(:info, "Welcome, #{user.name}.")
      |> redirect(to: return_to)
    else
      {:error, :not_allowed} ->
        Logger.warning("[auth] login denied — subject/email is not in the allowlist")
        login_failed(conn, "That account isn't allowed.")

      {:error, :subject_conflict} ->
        Logger.warning(
          "[auth] login refused — the allowlisted email is already bound to a different " <>
            "oidc_subject than the one presented (subject conflict, not an allowlist denial)"
        )

        login_failed(
          conn,
          "This account is already linked to a different sign-in. Contact the administrator " <>
            "to clear or update the stored sign-in link."
        )

      error ->
        Logger.warning("[auth] login failed: #{inspect(error)}")
        login_failed(conn, "Sign-in failed.")
    end
  end

  defp login_failed(conn, message) do
    conn
    |> delete_session(:oidc_state)
    |> put_flash(:error, message)
    |> redirect(to: ~p"/login")
  end

  @doc """
  Deliberately temporary cutover fallback (spec 2026-09-05 §6): "land Authentik alongside
  Google login... if the bind is wrong, recovery is one login away rather than a database
  restore." Nothing else in `lib/` sets `:google_oauth_flow` any more (Task 4 replaced the
  function that did), so `GoogleAuthController`'s `flow == "login"` branch was unreachable and
  a mis-set `OIDC_*` on deploy locked everyone out of the web with no second way in. This does
  exactly what `login/2` used to do before c000745. DELETE this together with
  `GoogleAuthController`'s `flow == "login"` branch once the Authentik migration is verified.
  """
  def login_via_google(conn, _params) do
    state = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    conn
    |> put_session(:google_oauth_state, state)
    |> put_session(:google_oauth_flow, "login")
    |> redirect(external: App.Google.OAuth.authorize_url(state, ["openid", "email"]))
  end

  def logout(conn, _params), do: UserAuth.log_out_user(conn)
end
