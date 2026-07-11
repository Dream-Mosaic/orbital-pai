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

  # ONE template that loops areas() (12) not states (553): linear, small payload, area-less
  # entities skipped for free. Renders JSON `[["light.kitchen","Kitchen"], …]`. See areas_map/0.
  @areas_template """
  {% set ns = namespace(items=[]) %}
  {%- for a in areas() -%}
  {%- for e in area_entities(a) -%}
  {% set ns.items = ns.items + [[e, area_name(a)]] %}
  {%- endfor -%}
  {%- endfor -%}
  {{ ns.items | tojson }}
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

  @doc """
  Render a Jinja template server-side: `POST /api/template` with `%{template: jinja}` →
  `{:ok, rendered_plaintext}`. HA returns text/plain; the body stays a string. A template
  render error surfaces as HA's `400` → `{:error, {:http, 400}}`.
  """
  def template(jinja) when is_binary(jinja) do
    with {:ok, %{url: url, token: token}} <- config() do
      case Req.post("#{url}/api/template", req_opts(token, json: %{template: jinja})) do
        {:ok, %{status: 200, body: body}} -> {:ok, to_string(body)}
        {:ok, %{status: 401}} -> {:error, :unauthorized}
        {:ok, %{status: s}} -> {:error, {:http, s}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  ONE entity's live state: `GET /api/states/<entity_id>` → `{:ok, entity_map}` (carries
  `attributes` incl. `device_class` for the garage check + the attrs `service_for` needs).
  `home_control` uses this instead of pulling all 553 states per call. 404 → `:not_found`.
  """
  def state(entity_id) when is_binary(entity_id) do
    with {:ok, %{url: url, token: token}} <- config() do
      case Req.get("#{url}/api/states/#{entity_id}", req_opts(token, [])) do
        {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
        {:ok, %{status: 200}} -> {:error, :bad_body}
        {:ok, %{status: 401}} -> {:error, :unauthorized}
        {:ok, %{status: 404}} -> {:error, :not_found}
        {:ok, %{status: s}} -> {:error, {:http, s}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  `%{entity_id => area_name}` for every area-assigned entity, via ONE `/api/template` render
  that loops `areas()`. This is the SOLE area source — no separate cache; the tool-level
  caches gate its fetch frequency. Area-less entities are simply absent from the map.
  """
  def areas_map do
    with {:ok, rendered} <- template(@areas_template),
         {:ok, pairs} when is_list(pairs) <- Jason.decode(rendered) do
      {:ok, Map.new(pairs, fn [id, area] -> {id, area} end)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :bad_body}
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
