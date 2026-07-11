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

  @impl true
  def declarations do
    [
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

  def cache_key(_, args), do: args

  @impl true
  def cache_invalidates("home_control"), do: ["home_state"]
  def cache_invalidates(_), do: []

  @impl true
  def bridge("home_state"),
    do: ["Let me check the house.", "One sec, looking at the house.", "Checking on that now."]

  def bridge("home_control"), do: ["On it.", "Sure — one sec.", "Doing that now."]
  def bridge(_), do: []

  @impl true
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

  defp reach_note(:not_configured), do: "the home hub isn't configured on this server"

  defp reach_note(:unauthorized),
    do: "the home hub rejected the access token — HOME_ASSISTANT_TOKEN needs attention"

  defp reach_note(reason), do: "couldn't reach the home hub (#{inspect(reason)})"
end
