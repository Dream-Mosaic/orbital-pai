defmodule AppWeb.AuthController do
  @moduledoc """
  Authentik sign-in (identity), distinct from Google connectors. `login/2` starts the Authentik
  consent (via `App.Auth.Oidc`) and stores a CSRF `state` under `:oidc_state` — a session key
  that belongs exclusively to this flow, never `:google_oauth_state`/`:google_oauth_flow` (those
  stay `GoogleAuthController`'s, for connectors). `callback/2` verifies the state, exchanges the
  code, reads the login claims, and resolves the row via `App.Users.upsert_from_oidc/1`.

  ## The app return branch

  Mirrors `AppWeb.GoogleAuthController`'s `return=app` handling exactly. `login/2` allowlists the
  literal string `"app"` (never a URL) from `params["return"]` and stores it under `:oidc_return`
  — analogous to `:google_oauth_return`, and just as deliberately never honoring an
  attacker-supplied redirect target. On success, `callback/2` mints a single-use code
  (`App.Auth.AppCode`) and deep-links to it (`AppWeb.AppLink.auth/1`) instead of redirecting to
  `:user_return_to`, but it still calls `UserAuth.log_in_user/2` first — the same device may also
  use the web monitor, so a browser session is established either way. Every failure path on the
  app flow deep-links back to `orbital://auth?status=error` (`AppWeb.AppLink.auth_error/0`)
  rather than stranding the browser on `/login`.
  """
  use AppWeb, :controller
  require Logger

  alias App.Auth.{AppCode, Oidc}
  alias App.Users
  alias AppWeb.{AppLink, UserAuth}

  def login_page(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: ~p"/")
    else
      render(conn, :login, current_user: nil)
    end
  end

  def login(conn, params) do
    # Allowlisted, never a URL taken from the caller -- see `GoogleAuthController.connect/2`,
    # which this mirrors: the only thing a client may ask for is WHICH of the two known return
    # branches to take, so `return` can never become an open redirect.
    target = if params["return"] == "app", do: "app", else: "web"
    state = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    case Oidc.authorize_url(state) do
      {:ok, url} ->
        conn
        |> put_session(:oidc_state, state)
        |> put_session(:oidc_return, target)
        |> redirect(external: url)

      {:error, reason} ->
        Logger.warning("[auth] could not build the Authentik authorize URL: #{inspect(reason)}")
        bail(conn, target, "Sign-in is unavailable right now. Please try again shortly.")
    end
  end

  # A failure BEFORE the hop to Authentik. Nothing has been stored in the session yet -- there is
  # no callback coming back to read it from -- so this takes the target from params instead, same
  # as `GoogleAuthController.bail/3`. An app-initiated login that dies here must still return to
  # the app rather than leaving it with no signal that anything happened.
  defp bail(conn, "app", _message), do: redirect(conn, external: AppLink.auth_error())

  defp bail(conn, _target, message) do
    conn |> put_flash(:error, message) |> redirect(to: ~p"/login")
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
      # it -- these keys included. Without this, a signed-out browser sent here by
      # `UserAuth.require_user/2` loses whatever it was originally asking for: for a connector
      # grant link that is the entire request, silently discarded; for the app flow, the return
      # target it needs below.
      return_to = get_session(conn, :user_return_to) || ~p"/"
      app_return? = get_session(conn, :oidc_return) == "app"

      conn = conn |> UserAuth.log_in_user(user) |> put_flash(:info, "Welcome, #{user.name}.")

      if app_return? do
        code = AppCode.mint(user.id)
        redirect(conn, external: AppLink.auth(code))
      else
        redirect(conn, to: return_to)
      end
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
    app_return? = get_session(conn, :oidc_return) == "app"

    conn =
      conn
      |> delete_session(:oidc_state)
      |> delete_session(:oidc_return)

    if app_return? do
      redirect(conn, external: AppLink.auth_error())
    else
      conn |> put_flash(:error, message) |> redirect(to: ~p"/login")
    end
  end

  def logout(conn, _params), do: UserAuth.log_out_user(conn)

  @doc """
  `POST /api/auth/exchange` — the app's second half of the code-for-token swap. Lives in the
  `:api` pipeline (no session, no CSRF token needed). The error is identical for an unknown,
  expired, or already-used code on purpose: distinguishing them would tell a caller replaying a
  captured code more than it should ever learn.
  """
  def exchange(conn, %{"code" => code}) when is_binary(code) do
    case AppCode.exchange(code) do
      {:ok, user_id} ->
        json(conn, %{"token" => UserAuth.socket_token(user_id)})

      {:error, :invalid} ->
        conn |> put_status(401) |> json(%{"error" => "invalid_code"})
    end
  end

  def exchange(conn, _params),
    do: conn |> put_status(401) |> json(%{"error" => "invalid_code"})
end
