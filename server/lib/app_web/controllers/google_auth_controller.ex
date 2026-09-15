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
  alias AppWeb.AppLink

  def connect(conn, params) do
    # Allowlisted, never a URL taken from the caller: the only thing a client may ask for is
    # WHICH of the two known return branches to take. Anything else is ignored rather than
    # honored, so `return` can never become an open redirect.
    target = if params["return"] == "app", do: "app", else: "web"

    if configured?() do
      grants = grants_from_params(params)
      scopes = Connectors.scopes_for(grants)

      case maybe_revoke_for_reduction(conn.assigns.current_user.id, params["account"], scopes) do
        :ok ->
          state = random_state()

          conn
          |> put_session(:google_oauth_state, state)
          |> put_session(:google_oauth_return, target)
          |> delete_session(:google_oauth_flow)
          |> redirect(external: OAuth.authorize_url(state, scopes))

        {:error, :revoke_failed} ->
          bail(conn, target, "Couldn't update Google access (revoke failed). Please try again.")
      end
    else
      bail(conn, target, "Google isn't configured (missing client credentials).")
    end
  end

  # A failure BEFORE the hop to Google. The return target has not been stored in the session
  # yet -- nothing is coming back through the callback to read it -- so this takes it from the
  # params instead. An app-initiated connect that dies here must STILL return to the app: the
  # alternative is the user stranded in a browser tab holding an error, with the app behind it
  # showing no sign anything happened.
  defp bail(conn, "app", message),
    do: app_return(conn, "Didn't complete", message, AppLink.connectors(:error))

  defp bail(conn, _target, message) do
    conn |> put_flash(:error, message) |> redirect(to: ~p"/")
  end

  def callback(conn, %{"state" => state} = params) do
    expected = get_session(conn, :google_oauth_state)

    cond do
      is_nil(expected) or state != expected ->
        finish(conn, :error, "Google connection failed (state mismatch). Please try again.")

      params["error"] ->
        finish(conn, :error, "Google connection cancelled.")

      true ->
        handle_code(conn, conn.assigns.current_user, params["code"])
    end
  end

  def callback(conn, _params),
    do: finish(conn, :error, "Google connection failed.")

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

  # Both branches describe the SAME outcome from one `kind`, so the app and the web can never
  # disagree about whether a flow succeeded. The app branch drops `message` on purpose -- see
  # `AppWeb.AppLink`'s moduledoc on why a deep link carries a status and no free text.
  defp finish(conn, kind, message) do
    target = get_session(conn, :google_oauth_return)

    conn =
      conn
      |> delete_session(:google_oauth_state)
      |> delete_session(:google_oauth_flow)
      |> delete_session(:google_oauth_return)

    if target == "app" do
      case kind do
        :info -> app_return(conn, "Connected", "", AppLink.connectors(kind))
        _ -> app_return(conn, "Didn't complete", message, AppLink.connectors(kind))
      end
    else
      conn |> put_flash(kind, message) |> redirect(to: ~p"/")
    end
  end

  defp random_state, do: 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp configured?,
    do:
      System.get_env("GOOGLE_CLIENT_ID") not in [nil, ""] and
        System.get_env("GOOGLE_CLIENT_SECRET") not in [nil, ""]

  # Same page the sign-in flow renders (AuthHTML's app_return) -- one template for every tab a
  # native-app flow can end in. See AuthController.app_return/4 for why it is a page, not a 302.
  defp app_return(conn, title, message, link) do
    conn
    |> put_view(html: AppWeb.AuthHTML)
    |> render(:app_return,
      title: title,
      body: String.trim("#{message} You can close this tab."),
      link: link
    )
  end
end
