defmodule App.Auth.Oidc do
  @moduledoc """
  Authentik OIDC client — this is the IDENTITY provider (who you are), distinct from
  `App.Google.OAuth`, which is the CONNECTOR provider (what you granted access to, i.e.
  Calendar/Gmail). They are deliberately separate modules serving different purposes and must
  not be merged.

  Builds the Authentik consent URL, exchanges an authorization code for tokens, and decodes
  the login claims (`sub`/`email`/`name`) from the resulting `id_token`.

  ## Discovery, not string-joining

  The authorization and token endpoints are fetched from the issuer's discovery document
  (`<issuer>.well-known/openid-configuration`), NOT derived by joining paths onto the issuer.
  Authentik's issuer carries the application slug (e.g.
  `https://auth.clausens.cloud/application/o/orbital/`) but the endpoints do not
  (`https://auth.clausens.cloud/application/o/authorize/`,
  `.../application/o/token/`) — joining would produce a 404. This is also the right shape for
  running against a different IdP (Keycloak, Okta): configure one issuer and the endpoints
  follow, rather than three URLs that must independently agree.

  Discovery is fetched lazily on first use (never at boot — a login that fails with a clear
  "identity provider unreachable" beats an app that will not start) and the endpoint pair is
  cached in `:persistent_term`. `reset_discovery_cache/0` is a test seam for clearing it between
  tests that stub different discovery responses.

  ## The id_token is decoded, not signature-verified

  This is deliberate and spec-legal — OIDC Core §3.1.3.7 point 6 permits skipping signature
  validation when the token is received directly from the token endpoint over TLS on a
  confidential client, which is exactly this flow. It mirrors what
  `App.Google.OAuth.email_from_id_token/1` already does. Recorded here because it reads like an
  oversight and is not; a JWKS client would add a moving part that secures nothing here.

  Config comes from `Application.get_env(:app, :oidc_*)` (wired in `config/runtime.exs` from
  `OIDC_ISSUER`/`OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET`/`OIDC_REDIRECT_URI`); Req options are
  overridable via `:oidc_req_opts` (test seam, same pattern as `:google_req_opts`).
  """

  @scopes ~w(openid email profile)
  @discovery_key {__MODULE__, :discovery}

  @doc "Whether OIDC is configured (client id present). Used to gate showing the login option."
  def configured? do
    is_binary(Application.get_env(:app, :oidc_client_id))
  end

  @doc """
  Fetch (and cache) the discovery document's `authorization_endpoint` and `token_endpoint`.
  Fetched lazily on first use, not at boot. Never raises: an unreachable or malformed discovery
  document is `{:error, :discovery_failed}`.
  """
  def discovery do
    case :persistent_term.get(@discovery_key, :not_cached) do
      :not_cached -> fetch_discovery()
      cached -> {:ok, cached}
    end
  end

  @doc "Test seam: clear the cached discovery document."
  def reset_discovery_cache do
    :persistent_term.erase(@discovery_key)
  catch
    _, _ -> :ok
  end

  @doc """
  Build the Authentik consent/login URL. `state` is echoed to the callback (CSRF guard).

  Returns `{:ok, url}`, or `{:error, :discovery_failed}` when the discovery document (which the
  authorization endpoint comes from) is unreachable — callers MUST handle the error case rather
  than redirecting to it; there is no bare-string return.
  """
  def authorize_url(state) do
    with {:ok, %{authorization_endpoint: endpoint}} <- discovery() do
      query =
        URI.encode_query(%{
          client_id: client_id(),
          redirect_uri: redirect_uri(),
          response_type: "code",
          scope: Enum.join(@scopes, " "),
          state: state
        })

      {:ok, endpoint <> "?" <> query}
    end
  end

  @doc "Exchange an authorization code for tokens."
  def exchange_code(code) do
    with {:ok, %{token_endpoint: endpoint}} <- discovery() do
      opts =
        [
          form: %{
            code: code,
            client_id: client_id(),
            client_secret: client_secret(),
            redirect_uri: redirect_uri(),
            grant_type: "authorization_code"
          },
          finch: App.Finch,
          receive_timeout: 8_000
        ] ++ App.Http.Retry.opts() ++ req_opts()

      case Req.post(endpoint, opts) do
        {:ok, %{status: 200, body: %{"access_token" => at, "id_token" => idt}}} ->
          {:ok, %{id_token: idt, access_token: at}}

        {:ok, %{status: 200, body: body}} ->
          {:error, {:unexpected_token_response, body}}

        {:ok, %{status: status}} ->
          {:error, {:http, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Decode `sub`, `email` and `name` from the id_token's payload (decoded, not
  signature-verified — see the moduledoc). Missing `sub` or missing/blank `email` is an
  error, not a partial map — a predicted operator error is an Authentik user created without an
  email, and this must fail cleanly rather than surface as a confusing allowlist denial. Every
  failure mode returns `{:error, _}`; nothing raises.
  """
  def claims_from_id_token(token) when is_binary(token) do
    with [_header, payload, _sig] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(json),
         %{"sub" => sub} when is_binary(sub) and sub != "" <- claims,
         %{"email" => email} when is_binary(email) and email != "" <- claims do
      {:ok, %{sub: sub, email: email, name: Map.get(claims, "name")}}
    else
      _ -> {:error, :invalid_id_token}
    end
  end

  def claims_from_id_token(_), do: {:error, :invalid_id_token}

  defp fetch_discovery do
    issuer = issuer()

    url =
      issuer
      |> String.trim_trailing("/")
      |> Kernel.<>("/.well-known/openid-configuration")

    opts = [finch: App.Finch, receive_timeout: 8_000] ++ App.Http.Retry.opts() ++ req_opts()

    case Req.get(url, opts) do
      {:ok,
       %{
         status: 200,
         body: %{"authorization_endpoint" => auth_ep, "token_endpoint" => token_ep}
       }} ->
        result = %{authorization_endpoint: auth_ep, token_endpoint: token_ep}
        :persistent_term.put(@discovery_key, result)
        {:ok, result}

      _ ->
        {:error, :discovery_failed}
    end
  rescue
    _ -> {:error, :discovery_failed}
  end

  defp issuer, do: Application.get_env(:app, :oidc_issuer)
  defp client_id, do: Application.get_env(:app, :oidc_client_id)
  defp client_secret, do: Application.get_env(:app, :oidc_client_secret)
  defp redirect_uri, do: Application.get_env(:app, :oidc_redirect_uri)
  defp req_opts, do: Application.get_env(:app, :oidc_req_opts, [])
end
