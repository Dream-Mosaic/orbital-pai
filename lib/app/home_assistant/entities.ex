defmodule App.HomeAssistant.Entities do
  @moduledoc """
  Pure smart-home entity logic — no I/O. Three jobs:

    * `classify/1` — bucket an entity: `:controllable` (the v1 write scope),
      `:read_only` (sensors — reportable, nothing to control), `:sensitive_read_only`
      (locks, alarm panels, garage covers — reportable but STRUCTURALLY uncontrollable),
      `:ignore` (noise the brain never sees).
    * `compact/1` / `compact_states/2` — squeeze raw `/api/states` entities into the small
      maps the brain reads (name, entity_id, domain, state, key attributes; nils dropped).
    * `service_for/3` — map a semantic action (`on`/`set_brightness`/…) to the HA
      `{service_domain, service, data}` for the entity's domain. **Sensitive domains have NO
      mapping here — that absence is the v1 safety model** (a misheard "unlock the door" has
      no code path to a service call). Don't add one.
  """

  @controllable ~w(light switch scene script media_player climate cover)
  @sensitive ~w(lock alarm_control_panel)
  @read_only ~w(sensor binary_sensor)

  @doc "The entity's domain (the entity_id segment before the dot)."
  def domain(%{"entity_id" => id}) when is_binary(id), do: id |> String.split(".") |> hd()
  def domain(_), do: nil

  @doc "Bucket an entity for the brain's view + the control gate."
  def classify(entity) do
    d = domain(entity)

    cond do
      d in @sensitive -> :sensitive_read_only
      d == "cover" and device_class(entity) == "garage" -> :sensitive_read_only
      d in @controllable -> :controllable
      d in @read_only -> :read_only
      true -> :ignore
    end
  end

  @doc """
  `(entity, action, value)` → `{:ok, {service_domain, service, data}}` (data WITHOUT
  entity_id — the caller merges it). Anything not `:controllable` → `{:error, :not_controllable}`;
  an unknown action for the domain → `{:error, :unknown_action}`; a value-requiring action
  without a number → `{:error, :needs_value}`.
  """
  def service_for(entity, action, value) do
    if classify(entity) == :controllable do
      map_action(domain(entity), action, value)
    else
      {:error, :not_controllable}
    end
  end

  # -- the mapping table (NO lock / alarm_control_panel / garage rows — structural safety) --

  defp map_action("light", "on", _), do: {:ok, {"light", "turn_on", %{}}}
  defp map_action("light", "off", _), do: {:ok, {"light", "turn_off", %{}}}
  defp map_action("light", "toggle", _), do: {:ok, {"light", "toggle", %{}}}

  defp map_action("light", "set_brightness", v) when is_number(v),
    do: {:ok, {"light", "turn_on", %{brightness_pct: round(clamp(v, 0, 100))}}}

  defp map_action("light", "set_brightness", _), do: {:error, :needs_value}

  defp map_action("switch", "on", _), do: {:ok, {"switch", "turn_on", %{}}}
  defp map_action("switch", "off", _), do: {:ok, {"switch", "turn_off", %{}}}
  defp map_action("switch", "toggle", _), do: {:ok, {"switch", "toggle", %{}}}

  defp map_action("scene", a, _) when a in ["activate", "on"],
    do: {:ok, {"scene", "turn_on", %{}}}

  defp map_action("script", a, _) when a in ["activate", "on"],
    do: {:ok, {"script", "turn_on", %{}}}

  defp map_action("media_player", "play", _), do: {:ok, {"media_player", "media_play", %{}}}
  defp map_action("media_player", "pause", _), do: {:ok, {"media_player", "media_pause", %{}}}
  defp map_action("media_player", "next", _), do: {:ok, {"media_player", "media_next_track", %{}}}
  defp map_action("media_player", "on", _), do: {:ok, {"media_player", "turn_on", %{}}}
  defp map_action("media_player", "off", _), do: {:ok, {"media_player", "turn_off", %{}}}

  defp map_action("media_player", "volume_set", v) when is_number(v),
    do: {:ok, {"media_player", "volume_set", %{volume_level: normalize_volume(v)}}}

  defp map_action("media_player", "volume_set", _), do: {:error, :needs_value}

  defp map_action("climate", "set_temperature", v) when is_number(v),
    do: {:ok, {"climate", "set_temperature", %{temperature: v}}}

  defp map_action("climate", "set_temperature", _), do: {:error, :needs_value}
  defp map_action("climate", "on", _), do: {:ok, {"climate", "turn_on", %{}}}
  defp map_action("climate", "off", _), do: {:ok, {"climate", "turn_off", %{}}}

  defp map_action("cover", "on", _), do: {:ok, {"cover", "open_cover", %{}}}
  defp map_action("cover", "off", _), do: {:ok, {"cover", "close_cover", %{}}}
  defp map_action("cover", "toggle", _), do: {:ok, {"cover", "toggle", %{}}}

  defp map_action(_domain, _action, _value), do: {:error, :unknown_action}

  # -- compaction --

  @doc "One entity → the small map the brain sees. Nil fields dropped."
  def compact(entity) do
    attrs = Map.get(entity, "attributes") || %{}

    %{
      entity_id: entity["entity_id"],
      name: attrs["friendly_name"] || entity["entity_id"],
      domain: domain(entity),
      state: entity["state"],
      target_temp_high: attrs["target_temp_high"],
      target_temp_low: attrs["target_temp_low"],
      device_class: attrs["device_class"],
      unit: attrs["unit_of_measurement"],
      brightness_pct: brightness_pct(attrs["brightness"]),
      temperature: attrs["temperature"],
      current_temperature: attrs["current_temperature"],
      media_title: attrs["media_title"],
      volume_level: attrs["volume_level"],
      position: attrs["current_position"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc """
  Raw `/api/states` list → compacted brain view: `:ignore` entities dropped, then an optional
  case-insensitive substring query over name / entity_id / domain (HA REST doesn't expose the
  area registry, so "kitchen" matches by naming convention — see the spec).
  """
  def compact_states(entities, query \\ nil) do
    entities
    |> Enum.filter(&(classify(&1) != :ignore))
    |> Enum.map(&compact/1)
    |> filter_query(query)
  end

  defp filter_query(list, nil), do: list

  defp filter_query(list, query) when is_binary(query) do
    q = query |> String.downcase() |> String.trim()

    if q == "" do
      list
    else
      Enum.filter(list, fn e ->
        String.contains?(String.downcase(e.name), q) or
          String.contains?(e.entity_id, q) or
          String.contains?(e.domain, q)
      end)
    end
  end

  defp filter_query(list, _), do: list

  @doc """
  Fuzzy name match, RANK-ORDERED (best Jaro first, so callers truncate by rank). Tokenize
  `name` (downcase, strip punctuation, plural-fold each token), keep entities whose
  name+entity_id contains ALL tokens, then order by `String.jaro_distance/2` (entity name vs
  the whole query) descending. Empty/blank name → the input list unchanged.
  """
  def match_name(entities, name) when is_binary(name) do
    toks = tokens(name)

    if toks == [] do
      entities
    else
      q = String.downcase(name)

      entities
      |> Enum.filter(&all_tokens?(&1, toks))
      |> Enum.sort_by(&name_jaro(&1, q), :desc)
    end
  end

  def match_name(entities, _), do: entities

  @doc """
  Top-`k` entity NAMES by Jaro against the full inventory, IGNORING the ALL-tokens gate —
  the "no exact match, did you mean…" list so the brain self-corrects in the same round.
  """
  def close_matches(entities, name, k \\ 3) when is_binary(name) do
    q = String.downcase(name)

    entities
    |> Enum.sort_by(&name_jaro(&1, q), :desc)
    |> Enum.take(k)
    |> Enum.map(& &1.name)
  end

  @doc "Add `:area` to a compacted entity from `area_map` (left off when the entity has no area)."
  def enrich(entity, area_map) do
    case Map.get(area_map, entity.entity_id) do
      nil -> entity
      area -> Map.put(entity, :area, area)
    end
  end

  @doc """
  Compose filters over compacted+enriched entities: area (case-insensitive exact, else UNIQUE
  substring — ambiguous matches nothing, never widens), domain (exact), state (exact), then
  `match_name` (which sets the final order). Any nil/blank criterion leaves that dimension open.
  """
  def filter(entities, criteria) do
    entities
    |> filter_area(Map.get(criteria, :area))
    |> filter_domain(Map.get(criteria, :domain))
    |> filter_state(Map.get(criteria, :state))
    |> filter_name(Map.get(criteria, :name))
  end

  @doc """
  House map over the model-visible set (`:ignore` dropped): `%{areas: [%{name, count}],
  domains: [%{name, count}], total: n, no_area: n}`. `no_area` = devices unreachable by an
  area filter. `entities` are RAW `/api/states` maps; `area_map` supplies the areas.
  """
  def index(entities, area_map) do
    visible =
      entities
      |> Enum.filter(&(classify(&1) != :ignore))
      |> Enum.map(&compact/1)
      |> Enum.map(&enrich(&1, area_map))

    %{
      areas: counts(visible, & &1[:area]),
      domains: counts(visible, & &1.domain),
      total: length(visible),
      no_area: Enum.count(visible, &is_nil(&1[:area]))
    }
  end

  # -- filter helpers --

  defp filter_area(entities, area) when is_binary(area) do
    q = area |> String.downcase() |> String.trim()

    cond do
      q == "" ->
        entities

      Enum.any?(entities, &(&1[:area] && String.downcase(&1[:area]) == q)) ->
        Enum.filter(entities, &(&1[:area] && String.downcase(&1[:area]) == q))

      true ->
        matching =
          entities
          |> Enum.map(& &1[:area])
          |> Enum.reject(&is_nil/1)
          |> Enum.filter(&String.contains?(String.downcase(&1), q))
          |> Enum.uniq()

        case matching do
          [only] -> Enum.filter(entities, &(&1[:area] == only))
          _ -> []
        end
    end
  end

  defp filter_area(entities, _), do: entities

  defp filter_domain(entities, domain) when is_binary(domain) do
    d = domain |> String.downcase() |> String.trim()
    if d == "", do: entities, else: Enum.filter(entities, &(&1.domain == d))
  end

  defp filter_domain(entities, _), do: entities

  defp filter_state(entities, state) when is_binary(state) do
    s = String.trim(state)
    if s == "", do: entities, else: Enum.filter(entities, &(&1.state == s))
  end

  defp filter_state(entities, _), do: entities

  defp filter_name(entities, name) when is_binary(name) do
    if String.trim(name) == "", do: entities, else: match_name(entities, name)
  end

  defp filter_name(entities, _), do: entities

  # -- name matching helpers --

  defp tokens(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.split()
    |> Enum.map(&fold_plural/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp fold_plural(token) do
    cond do
      Regex.match?(~r/(ch|sh|x|s|z)es$/, token) -> String.replace_suffix(token, "es", "")
      String.ends_with?(token, "ss") -> token
      String.ends_with?(token, "s") -> String.replace_suffix(token, "s", "")
      true -> token
    end
  end

  defp all_tokens?(entity, toks) do
    hay = String.downcase("#{entity.name} #{entity.entity_id}")
    Enum.all?(toks, &String.contains?(hay, &1))
  end

  defp name_jaro(entity, query), do: String.jaro_distance(String.downcase(entity.name), query)

  defp counts(entities, keyfun) do
    entities
    |> Enum.map(keyfun)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.map(fn {name, count} -> %{name: name, count: count} end)
    |> Enum.sort_by(& &1.name)
  end

  defp device_class(%{"attributes" => %{"device_class" => dc}}), do: dc
  defp device_class(_), do: nil

  defp brightness_pct(b) when is_number(b), do: round(b / 255 * 100)
  defp brightness_pct(_), do: nil

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  # spoken percent (0–100) or HA-native fraction (0.0–1.0) → HA's 0.0–1.0
  defp normalize_volume(v) when v > 1, do: clamp(v / 100, 0.0, 1.0)
  defp normalize_volume(v), do: clamp(v / 1, 0.0, 1.0)
end
