defmodule App.HomeAssistant do
  @moduledoc """
  Home Assistant REST adapter — the one HTTP surface for the smart home. Reads all entity
  states (`GET /api/states`) and calls services (`POST /api/services/<domain>/<service>`)
  against a public HA URL (Nabu Casa / tunnel) with a long-lived access token.

  Instance-wide shared infrastructure: one house, one URL, one token — NOT per-user (unlike
  Google accounts). Config: `:app, :home_assistant` → `%{url: ..., token: ...}` (set from
  HOME_ASSISTANT_URL / HOME_ASSISTANT_TOKEN in config/runtime.exs; absent = unconfigured and
  the tool isn't registered — see App.Config.home_assistant?/0). Req options are overridable
  via `:home_assistant_req_opts` (test seam, same as `:google_req_opts`). Errors flatten to
  tagged tuples (`:not_configured`, `:unauthorized`, `:not_found`, `{:http, status}`,
  transport reasons) — never a raw crash. `App.Http.Retry.opts/0` covers the cold-Finch-pool
  `:pool_not_available` first-call race (retries only request-never-executed failures, so the
  service POST is safe).
  """

  @doc "True when both URL and token are configured (App.Config.home_assistant?/0 gates on this)."
  def configured?, do: match?({:ok, _}, config())

  @doc "All entity states: `{:ok, [entity]}` — each a decoded map with entity_id/state/attributes."
  def states do
    with {:ok, %{url: url, token: token}} <- config() do
      case Req.get("#{url}/api/states", req_opts(token, [])) do
        {:ok, %{status: 200, body: body}} when is_list(body) -> {:ok, body}
        {:ok, %{status: 200}} -> {:error, :bad_body}
        {:ok, %{status: 401}} -> {:error, :unauthorized}
        {:ok, %{status: s}} -> {:error, {:http, s}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Call a service: `POST /api/services/<domain>/<service>` with a JSON body (include
  `entity_id` for entity services). `{:ok, body}` — HA echoes the changed states.
  """
  def call_service(domain, service, data) when is_map(data) do
    with {:ok, %{url: url, token: token}} <- config() do
      case Req.post("#{url}/api/services/#{domain}/#{service}", req_opts(token, json: data)) do
        {:ok, %{status: s, body: body}} when s in 200..299 -> {:ok, body}
        {:ok, %{status: 401}} -> {:error, :unauthorized}
        {:ok, %{status: 404}} -> {:error, :not_found}
        {:ok, %{status: s}} -> {:error, {:http, s}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp config do
    case Application.get_env(:app, :home_assistant) do
      %{url: url, token: token} = cfg
      when is_binary(url) and url != "" and is_binary(token) and token != "" ->
        {:ok, cfg}

      _ ->
        {:error, :not_configured}
    end
  end

  # 6s receive_timeout keeps one HA round trip well under the registry's 8s tool cap.
  defp req_opts(token, extra) do
    [auth: {:bearer, token}, finch: App.Finch, receive_timeout: 6_000] ++
      App.Http.Retry.opts() ++ extra ++ Application.get_env(:app, :home_assistant_req_opts, [])
  end
end
