defmodule App.Tools.HomeAssistant do
  @moduledoc """
  Voice smart-home control (Home Assistant REST). Three brain-callable functions: `home_index`
  (a compact rooms/domains map to orient the brain), `home_find` (fuzzy area/domain/name search
  returning the exact entity_ids), and `home_control` (one attribute-aware action on one
  entity_id). Safety is STRUCTURAL:
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
  alias App.HomeAssistant.Media

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
        name: "home_control",
        description:
          "Act on ONE smart-home device by entity_id (find it with home_find first). Actions: " <>
            "on, off, toggle, set_brightness (0-100), set_temperature (°F — a heat_cool " <>
            "thermostat recentres its band), set_position (covers, 0-100), set_speed (fans, " <>
            "0-100), volume_set (0-100), activate (scene/script), play, pause, next. Locks, " <>
            "alarm panels, and garage doors cannot be operated — report their state instead.",
        parameters: %{
          type: "object",
          properties: %{
            entity_id: %{
              type: "string",
              description: "The exact entity_id from home_find (e.g. \"light.kitchen\")."
            },
            action: %{
              type: "string",
              enum: [
                "on",
                "off",
                "toggle",
                "set_brightness",
                "set_temperature",
                "set_position",
                "set_speed",
                "volume_set",
                "activate",
                "play",
                "pause",
                "next"
              ],
              description: "The semantic action to perform."
            },
            value: %{
              type: "number",
              description: "brightness/position/speed/volume 0-100; set_temperature is degrees F."
            }
          },
          required: ["entity_id", "action"]
        }
      },
      %{
        name: "play_music",
        description:
          "Play music through the smart home (Music Assistant). Give what to play (query) and, " <>
            "if the user names a room/speaker, the player. Infer media_type from how they " <>
            "phrase it (an artist, a specific song/track, an album, a playlist, or a radio " <>
            "station) — omit it if you're not sure and let Music Assistant guess. enqueue " <>
            "defaults to \"replace\" (play now); use \"add\" to queue at the end or \"next\" to " <>
            "play right after the current track. To pause, skip, change volume, or ask what's " <>
            "playing, use home_control on that speaker instead.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{
              type: "string",
              description: "What to play — an artist, song, album, playlist, or station name."
            },
            player: %{
              type: "string",
              description:
                "Room or speaker name to play on (e.g. \"kitchen\"). Omit if there's only one " <>
                  "player or the user didn't say."
            },
            media_type: %{
              type: "string",
              enum: ["artist", "track", "album", "playlist", "radio"],
              description: "What kind of thing query refers to; omit if unsure."
            },
            enqueue: %{
              type: "string",
              enum: ["replace", "add", "next"],
              description:
                "replace (default, play now), add (queue at the end), or next (play right " <>
                  "after the current track)."
            }
          },
          required: ["query"]
        }
      }
    ]
  end

  @impl true
  def cache_ttl("home_index"), do: 60_000
  def cache_ttl("home_find"), do: 10_000
  def cache_ttl(_), do: nil

  @impl true
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
  def cache_invalidates("home_control"), do: ["home_index", "home_find"]
  def cache_invalidates(_), do: []

  @impl true
  def bridge("home_index"), do: ["Let me look at the house.", "One sec — checking the house."]

  def bridge("home_find"), do: ["Let me find that.", "One sec — looking.", "Checking the house."]

  def bridge("home_control"), do: ["On it.", "Sure — one sec.", "Doing that now."]
  def bridge("play_music"), do: ["Cueing that up.", "One sec — let's get that going.", "On it."]
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

  def execute("home_control", %{"entity_id" => id, "action" => action} = args, _ctx)
      when is_binary(id) and is_binary(action) do
    case HomeAssistant.state(id) do
      {:ok, entity} ->
        control(entity, id, action, num(Map.get(args, "value")))

      {:error, :not_found} ->
        {:ok,
         %{note: "no device with entity_id #{inspect(id)} — call home_find to find the right one"}}

      {:error, reason} ->
        {:ok, %{error: reach_note(reason)}}
    end
  end

  def execute("home_control", _args, _ctx),
    do:
      {:ok,
       %{
         note:
           "home_control needs an entity_id and an action — call home_find first to find the entity_id"
       }}

  def execute("play_music", %{"query" => query} = args, _ctx)
      when is_binary(query) and query != "" do
    case HomeAssistant.states() do
      {:ok, raw} ->
        play(
          Media.ma_players(raw),
          query,
          str(Map.get(args, "player")),
          str(Map.get(args, "media_type")),
          str(Map.get(args, "enqueue"))
        )

      {:error, reason} ->
        {:ok, %{error: reach_note(reason)}}
    end
  end

  def execute("play_music", _args, _ctx),
    do: {:ok, %{note: "play_music needs a query — what you want to play"}}

  defp control(entity, id, action, value) do
    case Entities.service_for(entity, action, value) do
      {:ok, {domain, service, data}} ->
        case HomeAssistant.call_service(domain, service, Map.put(data, :entity_id, id)) do
          {:ok, _} ->
            {:ok,
             %{done: action, entity: Entities.compact(entity).name, entity_id: id, set: data}}

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
               "actions: on, off, toggle, set_brightness, set_temperature, set_position, " <>
               "set_speed, volume_set, activate, play, pause, next"
         }}

      {:error, :needs_value} ->
        {:ok,
         %{
           note:
             "#{inspect(action)} needs a numeric value (brightness/volume/position/speed 0-100, temperature in °F)"
         }}
    end
  end

  defp play([], _query, _player, _media_type, _enqueue),
    do: {:ok, %{note: "no music players are set up (Music Assistant not configured?)"}}

  defp play(players, query, player_name, media_type, enqueue) do
    case Media.resolve_player(players, player_name) do
      {:error, :none} ->
        {:ok,
         %{
           note: "I don't see a speaker called #{player_name} — I have: #{player_names(players)}"
         }}

      {:error, :ambiguous} ->
        {:ok,
         %{
           note: "which room? I can play on: #{player_names(players)}",
           players: Enum.map(players, & &1.name)
         }}

      {:ok, p} ->
        data =
          Media.play_media_data(query, media_type, enqueue) |> Map.put(:entity_id, p.entity_id)

        case HomeAssistant.call_service("music_assistant", "play_media", data) do
          {:ok, _} ->
            {:ok, %{playing: query, player: p.name, enqueue: data.enqueue}}

          {:error, reason} ->
            {:ok,
             %{error: "couldn't play that — the music service had trouble (#{inspect(reason)})"}}
        end
    end
  end

  defp player_names(players), do: players |> Enum.map(& &1.name) |> Enum.join(", ")

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
