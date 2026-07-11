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

  defp device_class(%{"attributes" => %{"device_class" => dc}}), do: dc
  defp device_class(_), do: nil

  defp brightness_pct(b) when is_number(b), do: round(b / 255 * 100)
  defp brightness_pct(_), do: nil

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  # spoken percent (0–100) or HA-native fraction (0.0–1.0) → HA's 0.0–1.0
  defp normalize_volume(v) when v > 1, do: clamp(v / 100, 0.0, 1.0)
  defp normalize_volume(v), do: clamp(v / 1, 0.0, 1.0)
end
