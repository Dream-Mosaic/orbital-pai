defmodule AppWeb.GoogleAuthController do
  @moduledoc """
  The Google OAuth connect flow. `connect` stores a random CSRF `state` in the session and
  redirects to Google's consent screen; `callback` verifies the state, exchanges the code,
  upserts the account, and redirects home with a flash. Run it once per account to connect.
  """
  use AppWeb, :controller
  require Logger

  alias App.Google.{Account, Accounts, Connectors, OAuth}
  alias App.Repo

  def connect(conn, params) do
    if configured?() do
      grants = grants_from_params(params)
      scopes = Connectors.scopes_for(grants)

      case maybe_revoke_for_reduction(conn.assigns.current_user.id, params["account"], scopes) do
        :ok ->
          state = random_state()

          conn
          |> put_session(:google_oauth_state, state)
          |> delete_session(:google_oauth_flow)
          |> redirect(external: OAuth.authorize_url(state, scopes))

        {:error, :revoke_failed} ->
          conn
          |> put_flash(:error, "Couldn't update Google access (revoke failed). Please try again.")
          |> redirect(to: ~p"/")
      end
    else
      conn
      |> put_flash(:error, "Google isn't configured (missing client credentials).")
      |> redirect(to: ~p"/")
    end
  end

  def callback(conn, %{"state" => state} = params) do
    expected = get_session(conn, :google_oauth_state)

    cond do
      is_nil(expected) or state != expected ->
        finish(conn, :error, "Google connection failed (state mismatch). Please try again.")

      get_session(conn, :google_oauth_flow) == "login" ->
        handle_login(conn, params)

      params["error"] ->
        finish(conn, :error, "Google connection cancelled.")

      true ->
        handle_code(conn, conn.assigns.current_user, params["code"])
    end
  end

  def callback(conn, _params),
    do: finish(conn, :error, "Google connection failed.")

  defp handle_login(conn, %{"code" => code}) do
    with {:ok, oauth} <- OAuth.exchange_code(code),
         email when is_binary(email) <- OAuth.email_from_id_token(oauth.id_token) do
      Logger.info("[auth] login callback resolved email: #{email}")

      case App.Users.upsert_allowed(email) do
        {:ok, user} ->
          conn
          |> AppWeb.UserAuth.log_in_user(user)
          |> put_flash(:info, "Welcome, #{user.name}.")
          |> redirect(to: ~p"/")

        {:error, :not_allowed} ->
          Logger.warning("[auth] login denied — #{email} is not in the allowlist")
          login_failed(conn, "That account isn't allowed.")
      end
    else
      error ->
        Logger.warning("[auth] login failed before the allowlist check: #{inspect(error)}")
        login_failed(conn, "Sign-in failed.")
    end
  end

  defp handle_login(conn, _), do: finish(conn, :error, "Sign-in failed (no code).")

  defp login_failed(conn, message) do
    conn
    |> delete_session(:google_oauth_flow)
    |> delete_session(:google_oauth_state)
    |> put_flash(:error, message)
    |> redirect(to: ~p"/login")
  end

  defp handle_code(conn, _user, nil),
    do: finish(conn, :error, "Google connection failed (no code).")

  defp handle_code(conn, user, code) do
    with {:ok, oauth} <- OAuth.exchange_code(code),
         {:ok, account} <- Accounts.upsert_from_oauth(oauth, user.id) do
      finish(conn, :info, "Connected #{account.email}.")
    else
      error ->
        Logger.warning("[google-auth] callback failed: #{inspect(error)}")
        finish(conn, :error, "Google connection failed.")
    end
  end

  # Per-connector levels from query params, e.g. ?calendar=read -> %{calendar: :read}. A bare
  # connect (no connector params) defaults to full calendar, preserving the original behavior.
  defp grants_from_params(params) do
    grants =
      for conn <- Connectors.all(),
          level = params[Atom.to_string(conn)],
          level in ["read", "write"],
          into: %{} do
        {conn, String.to_existing_atom(level)}
      end

    # A bare "Connect account" (no account context, no connector params) defaults to full calendar,
    # preserving one-click connect. When editing an existing account, empty grants mean "remove all".
    if grants == %{} and is_nil(params["account"]), do: %{calendar: :write}, else: grants
  end

  # When changing an existing account whose grant is being reduced, revoke its refresh token first —
  # Google accumulates granted scopes, so a scope set can't shrink via incremental consent.
  defp maybe_revoke_for_reduction(_user_id, nil, _scopes), do: :ok

  defp maybe_revoke_for_reduction(user_id, account_id, scopes) do
    with {id, ""} <- Integer.parse(account_id),
         account when not is_nil(account) <- Repo.get_by(Account, id: id, user_id: user_id),
         true <- Connectors.reduction?(account.scope, scopes) do
      case OAuth.revoke(account.refresh_token) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[google-auth] revoke failed: #{inspect(reason)}")
          {:error, :revoke_failed}
      end
    else
      _ -> :ok
    end
  end

  defp finish(conn, kind, message) do
    conn
    |> delete_session(:google_oauth_state)
    |> delete_session(:google_oauth_flow)
    |> put_flash(kind, message)
    |> redirect(to: ~p"/")
  end

  defp random_state, do: 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp configured?,
    do:
      System.get_env("GOOGLE_CLIENT_ID") not in [nil, ""] and
        System.get_env("GOOGLE_CLIENT_SECRET") not in [nil, ""]
end
