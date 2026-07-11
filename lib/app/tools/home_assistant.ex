defmodule App.Tools.HomeAssistant do
  @moduledoc """
  Voice smart-home control (Home Assistant REST). Two brain-callable functions: `home_state`
  (read — compacted entity states, optional query filter; how the brain discovers entity_ids)
  and `home_control` (write — one semantic action on one entity_id). Safety is STRUCTURAL:
  locks, alarm panels, and garage-class covers classify `:sensitive_read_only` and have no
  action→service mapping (App.HomeAssistant.Entities), so a control call on them returns a
  benign note — it can never act. Instance-wide (one house, both users; nothing user-scoped).
  Every failure flattens to `{:ok, %{note | error}}` the brain can relay — never a crash.
  Registered into the config's tool list ONLY when App.Config.home_assistant?/0 (URL + token
  present), so a disabled instance's brain never sees these declarations.
  """
  @behaviour App.Tools.Tool

  alias App.HomeAssistant
  alias App.HomeAssistant.Entities

  # Soft cap on the no-query view so a huge install can't flood the model.
  @entity_cap 150

  # Soft cap on home_find rows before the result shape switches to a summary (Task 5).
  @find_cap 20

  @impl true
  def declarations do
    [
      %{
        name: "home_index",
        description:
          "A compact map of the smart home (Home Assistant): the rooms (areas) with device " <>
            "counts, the device types (domains) with counts, the total device count, and how " <>
            "many devices have no room assigned. Call this to learn what rooms and device types " <>
            "exist before searching with home_find.",
        parameters: %{type: "object", properties: %{}, required: []}
      },
      %{
        name: "home_find",
        description:
          "Search the smart home. Pass the room (area) AND device type (domain) whenever you " <>
            "know them so ONE search pins the target (e.g. area:\"Kitchen\", domain:\"light\"). " <>
            "Optional: name (fuzzy), state (e.g. \"on\", \"open\", \"heat_cool\"). Returns lean " <>
            "rows (entity_id, name, area, domain, state, key attributes) for the exact entity_ids " <>
            "to pass to home_control. If it returns close_matches, pick the right one and act; if " <>
            "nothing matches, ASK what the device is called — don't keep searching.",
        parameters: %{
          type: "object",
          properties: %{
            name: %{
              type: "string",
              description: "Fuzzy device/friendly-name search (e.g. \"thermostat\")."
            },
            area: %{type: "string", description: "Room name from home_index (e.g. \"Kitchen\")."},
            domain: %{
              type: "string",
              description: "Device type (e.g. \"light\", \"cover\", \"climate\", \"fan\")."
            },
            state: %{type: "string", description: "Exact state filter (e.g. \"on\", \"open\")."}
          },
          required: []
        }
      },
      %{
        name: "home_state",
        description:
          "Current state of the smart-home devices (Home Assistant): lights, switches, scenes, " <>
            "scripts, media players, thermostats, covers/blinds, sensors — plus view-only locks, " <>
            "alarm, and garage door. Returns each entity's friendly name, entity_id, domain, " <>
            "state, and key attributes (brightness, temperature, media, position). Use it to " <>
            "answer questions like \"is the garage open?\" and to find the exact entity_id " <>
            "before calling home_control.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{
              type: "string",
              description:
                "Optional filter: a name, room, or domain substring (e.g. \"kitchen\", " <>
                  "\"light\", \"thermostat\"). Omit to list everything."
            }
          },
          required: []
        }
      },
      %{
        name: "home_control",
        description:
          "Act on ONE smart-home device by entity_id (find it with home_state first). " <>
            "Actions: on, off, toggle, set_brightness (value 0-100), set_temperature " <>
            "(value in °F), activate (scene/script), play, pause, next, volume_set " <>
            "(value 0-100). Locks, alarm panels, and garage doors cannot be operated — " <>
            "this tool is structurally unable to; report their state instead.",
        parameters: %{
          type: "object",
          properties: %{
            entity_id: %{
              type: "string",
              description: "The exact entity_id from home_state (e.g. \"light.kitchen\")."
            },
            action: %{
              type: "string",
              enum: [
                "on",
                "off",
                "toggle",
                "set_brightness",
                "set_temperature",
                "activate",
                "play",
                "pause",
                "next",
                "volume_set"
              ],
              description: "The semantic action to perform."
            },
            value: %{
              type: "number",
              description:
                "For set_brightness / volume_set: 0-100. For set_temperature: degrees F."
            }
          },
          required: ["entity_id", "action"]
        }
      }
    ]
  end

  @impl true
  def cache_ttl("home_index"), do: 60_000
  def cache_ttl("home_find"), do: 10_000
  def cache_ttl("home_state"), do: 10_000
  def cache_ttl(_), do: nil

  @impl true
  # Normalize the query so "Kitchen" / " kitchen " hit the same 10s cache entry.
  def cache_key("home_state", args) do
    case Map.get(args, "query") do
      q when is_binary(q) -> %{"query" => q |> String.downcase() |> String.trim()}
      _ -> %{"query" => ""}
    end
  end

  def cache_key("home_find", args) do
    %{
      "name" => norm(Map.get(args, "name")),
      "area" => norm(Map.get(args, "area")),
      "domain" => norm(Map.get(args, "domain")),
      "state" => norm(Map.get(args, "state"))
    }
  end

  def cache_key(_, args), do: args

  @impl true
  def cache_invalidates("home_control"), do: ["home_state"]
  def cache_invalidates(_), do: []

  @impl true
  def bridge("home_index"), do: ["Let me look at the house.", "One sec — checking the house."]

  def bridge("home_find"), do: ["Let me find that.", "One sec — looking.", "Checking the house."]

  def bridge("home_state"),
    do: ["Let me check the house.", "One sec, looking at the house.", "Checking on that now."]

  def bridge("home_control"), do: ["On it.", "Sure — one sec.", "Doing that now."]
  def bridge(_), do: []

  @impl true
  def execute("home_index", _args, _ctx) do
    case HomeAssistant.states() do
      {:ok, raw} -> {:ok, Entities.index(raw, area_map_or_empty())}
      {:error, reason} -> {:ok, %{error: reach_note(reason)}}
    end
  end

  def execute("home_find", args, _ctx) do
    name = str(Map.get(args, "name"))
    area = str(Map.get(args, "area"))

    case HomeAssistant.states() do
      {:ok, raw} ->
        find(raw, name, area, str(Map.get(args, "domain")), str(Map.get(args, "state")))

      {:error, reason} ->
        {:ok, %{error: reach_note(reason)}}
    end
  end

  def execute("home_state", args, _ctx) do
    case HomeAssistant.states() do
      {:ok, raw} ->
        {:ok, state_result(Entities.compact_states(raw, Map.get(args, "query")))}

      {:error, reason} ->
        {:ok, %{error: reach_note(reason)}}
    end
  end

  def execute("home_control", %{"entity_id" => id, "action" => action} = args, _ctx)
      when is_binary(id) and is_binary(action) do
    case HomeAssistant.states() do
      {:ok, raw} ->
        control(Enum.find(raw, &(&1["entity_id"] == id)), id, action, num(Map.get(args, "value")))

      {:error, reason} ->
        {:ok, %{error: reach_note(reason)}}
    end
  end

  def execute("home_control", _args, _ctx),
    do:
      {:ok,
       %{
         note:
           "home_control needs an entity_id and an action — call home_state first to find the entity_id"
       }}

  defp state_result([]),
    do: %{
      entities: [],
      note: "no matching devices — try home_state without a query to see everything"
    }

  defp state_result(entities) when length(entities) > @entity_cap do
    %{
      entities: Enum.take(entities, @entity_cap),
      count: length(entities),
      truncated: true,
      note: "large home — showing #{@entity_cap} of #{length(entities)}; narrow with a query"
    }
  end

  defp state_result(entities), do: %{entities: entities, count: length(entities)}

  defp control(nil, id, _action, _value),
    do:
      {:ok,
       %{note: "no device with entity_id #{inspect(id)} — call home_state to find the right one"}}

  defp control(entity, id, action, value) do
    case Entities.service_for(entity, action, value) do
      {:ok, {domain, service, data}} ->
        case HomeAssistant.call_service(domain, service, Map.put(data, :entity_id, id)) do
          {:ok, _} ->
            {:ok, %{done: action, entity: Entities.compact(entity).name, entity_id: id}}

          {:error, reason} ->
            {:ok, %{error: service_note(reason, id)}}
        end

      {:error, :not_controllable} ->
        {:ok,
         %{
           note:
             "#{Entities.compact(entity).name} is view-only — I'm not set up to control locks, " <>
               "alarms, or the garage. I can report its state."
         }}

      {:error, :unknown_action} ->
        {:ok,
         %{
           note:
             "#{inspect(action)} isn't something I can do to a #{Entities.domain(entity)} — " <>
               "actions: on, off, toggle, set_brightness, set_temperature, activate, play, " <>
               "pause, next, volume_set"
         }}

      {:error, :needs_value} ->
        {:ok,
         %{
           note:
             "#{inspect(action)} needs a numeric value (brightness/volume 0-100, temperature in °F)"
         }}
    end
  end

  # Gemini occasionally sends numbers as strings — coerce, never crash.
  defp num(v) when is_number(v), do: v

  defp num(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp num(_), do: nil

  defp service_note(:not_found, id),
    do: "the home hub didn't recognize that service for #{inspect(id)}"

  defp service_note(reason, _id), do: reach_note(reason)

  # areas_map is best-effort for the index (no area was requested): degrade to no areas on failure.
  defp area_map_or_empty do
    case HomeAssistant.areas_map() do
      {:ok, map} -> map
      {:error, _} -> %{}
    end
  end

  # Every uncached home_find fetches states/0 + areas_map/0 (spec: Caching) — the by_area
  # breakdown needs enrichment even with no area filter. A REQUESTED area with a failed
  # areas_map MUST NOT widen (C1) → error, zero rows; a failed areas_map with NO area requested
  # degrades to no-area enrichment (the breakdown then buckets those as "no area").
  defp find(raw, name, area, domain, state) do
    case HomeAssistant.areas_map() do
      {:error, _} when is_binary(area) ->
        {:ok, %{error: "couldn't resolve rooms right now — try by device name"}}

      result ->
        area_map =
          case result do
            {:ok, map} -> map
            {:error, _} -> %{}
          end

        visible =
          raw
          |> Enum.filter(&(Entities.classify(&1) != :ignore))
          |> Enum.map(&Entities.compact/1)
          |> Enum.map(&Entities.enrich(&1, area_map))

        matches =
          Entities.filter(visible, %{area: area, domain: domain, state: state, name: name})

        {:ok, shape(matches, visible, name)}
    end
  end

  defp shape(matches, visible, name) do
    count = length(matches)

    cond do
      count == 0 ->
        empty_shape(visible, name)

      count <= @find_cap ->
        %{entities: rows(matches), count: count}

      is_binary(name) ->
        %{
          entities: rows(Enum.take(matches, @find_cap)),
          count: count,
          note: "showing the 20 closest — add an area or domain to narrow"
        }

      true ->
        %{
          by_area: by_area(matches),
          count: count,
          note: "too many — add a room (rooms: #{rooms_hint(matches)}) or a device name"
        }
    end
  end

  defp empty_shape(visible, name) when is_binary(name) do
    %{
      entities: [],
      close_matches: Entities.close_matches(visible, name),
      note:
        "no exact match — did you mean one of these? If not, ASK the user what the device is called."
    }
  end

  defp empty_shape(_visible, _name) do
    %{
      entities: [],
      count: 0,
      note:
        "nothing matched those filters — try a different room or device name, or ASK the user."
    }
  end

  # Lean rows for multi-match; the full extended compact for a single match (M5).
  @lean_keys [
    :entity_id,
    :name,
    :area,
    :domain,
    :state,
    :brightness_pct,
    :temperature,
    :target_temp_high,
    :target_temp_low,
    :media_title,
    :volume_level,
    :position
  ]

  defp rows([single]), do: [single]
  defp rows(entities), do: Enum.map(entities, &Map.take(&1, @lean_keys))

  defp by_area(matches) do
    matches |> Enum.map(&(&1[:area] || "no area")) |> Enum.frequencies()
  end

  defp rooms_hint(matches) do
    matches
    |> Enum.map(& &1[:area])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join(", ")
  end

  # nil unless a non-blank string (nil = "that dimension unfiltered").
  defp str(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      s -> s
    end
  end

  defp str(_), do: nil

  defp norm(v) when is_binary(v), do: v |> String.downcase() |> String.trim()
  defp norm(_), do: ""

  defp reach_note(:not_configured), do: "the home hub isn't configured on this server"

  defp reach_note(:unauthorized),
    do: "the home hub rejected the access token — HOME_ASSISTANT_TOKEN needs attention"

  defp reach_note(reason), do: "couldn't reach the home hub (#{inspect(reason)})"
end
