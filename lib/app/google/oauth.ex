defmodule App.Google.OAuth do
  @moduledoc """
  Google OAuth2 (authorization-code flow) HTTP, no DB. Builds the consent URL, exchanges an
  auth code for tokens, refreshes an access token, and decodes the account email from the
  id_token. Credentials come from env (`GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET`); the redirect
  URI from app config; Req options are overridable via `:google_req_opts` (test seam, same as
  `App.Tools.Weather`).
  """

  @auth_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @revoke_url "https://oauth2.googleapis.com/revoke"

  @doc "Build the Google consent URL for `scopes`. `state` is echoed to the callback (CSRF guard)."
  def authorize_url(state, scopes) do
    query =
      URI.encode_query(%{
        client_id: client_id(),
        redirect_uri: redirect_uri(),
        response_type: "code",
        scope: Enum.join(scopes, " "),
        access_type: "offline",
        prompt: "consent",
        include_granted_scopes: "true",
        state: state
      })

    @auth_url <> "?" <> query
  end

  @doc "Exchange an authorization code for tokens."
  def exchange_code(code) do
    case post_token(%{
           code: code,
           client_id: client_id(),
           client_secret: client_secret(),
           redirect_uri: redirect_uri(),
           grant_type: "authorization_code"
         }) do
      {:ok, %{"access_token" => at, "refresh_token" => rt, "expires_in" => exp} = body} ->
        {:ok,
         %{
           access_token: at,
           refresh_token: rt,
           expires_in: exp,
           id_token: body["id_token"],
           scope: body["scope"]
         }}

      {:ok, body} ->
        {:error, {:unexpected_token_response, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Exchange a refresh token for a fresh access token."
  def refresh(refresh_token) do
    case post_token(%{
           refresh_token: refresh_token,
           client_id: client_id(),
           client_secret: client_secret(),
           grant_type: "refresh_token"
         }) do
      {:ok, %{"access_token" => at, "expires_in" => exp}} ->
        {:ok, %{access_token: at, expires_in: exp}}

      {:ok, %{"error" => "invalid_grant"}} ->
        {:error, :invalid_grant}

      {:ok, body} ->
        {:error, {:unexpected_token_response, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Decode the account email from the id_token's payload. The token came over TLS directly from
  Google's token endpoint, so we trust it without verifying the signature.
  """
  def email_from_id_token(nil), do: nil

  def email_from_id_token(id_token) when is_binary(id_token) do
    with [_header, payload, _sig] <- String.split(id_token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"email" => email}} <- Jason.decode(json) do
      email
    else
      _ -> nil
    end
  end

  @doc "Revoke a token (access or refresh) at Google's revoke endpoint. `:ok` on success."
  def revoke(token) do
    opts =
      [form: %{token: token}, finch: App.Finch, receive_timeout: 8_000] ++
        App.Http.Retry.opts() ++ req_opts()

    case Req.post(@revoke_url, opts) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A 200 returns the token body; a 4xx with a JSON `error` body is returned as {:ok, body} so
  # callers can pattern-match the error (e.g. invalid_grant); other failures are {:error, _}.
  defp post_token(form) do
    opts =
      [form: form, finch: App.Finch, receive_timeout: 8_000] ++
        App.Http.Retry.opts() ++ req_opts()

    case Req.post(@token_url, opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{body: %{"error" => _} = body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp client_id, do: System.fetch_env!("GOOGLE_CLIENT_ID")
  defp client_secret, do: System.fetch_env!("GOOGLE_CLIENT_SECRET")

  defp redirect_uri,
    do:
      Application.get_env(
        :app,
        :google_redirect_uri,
        "http://localhost:8787/auth/google/callback"
      )

  defp req_opts, do: Application.get_env(:app, :google_req_opts, [])
end
