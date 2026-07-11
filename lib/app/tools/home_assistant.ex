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
  def bridge("home_state"),
    do: ["Let me check the house.", "One sec, looking at the house.", "Checking on that now."]

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

  defp reach_note(:not_configured), do: "the home hub isn't configured on this server"

  defp reach_note(:unauthorized),
    do: "the home hub rejected the access token — HOME_ASSISTANT_TOKEN needs attention"

  defp reach_note(reason), do: "couldn't reach the home hub (#{inspect(reason)})"
end
