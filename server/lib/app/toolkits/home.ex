defmodule App.Toolkits.Home do
  @moduledoc "The house (Home Assistant) as a toolkit: home_control, home_status, play_music."
  @behaviour App.Toolkits.Toolkit

  alias App.HomeAssistant
  alias App.HomeAssistant.Phrases

  # The house's own names come from `App.HomeAssistant.phrases/0` (published once per directory
  # build); this is the vocabulary that needs no house. Over-opening is the bias: a false
  # positive costs a few declarations for one turn, a miss costs a model round.
  @generic ~w(light lights lamp lamps switch plug outlet fan fans thermostat heat heater ac aircon
              blinds shades curtains fireplace music song songs playlist album speaker speakers
              volume tv television scene nightlight dim brighter darker garage lock unlock alarm
              play pause resume skip louder quieter mute unmute) ++
             [
               "turn on",
               "turn off",
               "switch on",
               "switch off",
               "air conditioning",
               "turn it up",
               "turn it down",
               "turn up",
               "turn down"
             ]

  @impl true
  def id, do: "home"

  @impl true
  def summary,
    do:
      "the house: lights, switches, the fireplace, the thermostat, fans, blinds, speakers and music"

  @impl true
  def enabled?(_cfg), do: App.Config.home_assistant?()

  @impl true
  def tools, do: [App.Tools.HomeAssistant]

  @impl true
  def guidance do
    "You're controlling the house through Home Assistant. Pass the user's own words as targets " <>
      "(\"gaming lights\", \"the fireplace\", \"basement\") — the server resolves names, rooms, typos " <>
      "and aliases, so don't search first and never invent entity_ids. One home_control call can act " <>
      "on several targets. If the result asks you to choose, name the top two or three options and " <>
      "ask which; never guess. If something is offline, say so plainly — never claim it worked. " <>
      "A room, or \"all the lights\", only ever switches lights. Locks, the alarm and the garage " <>
      "door are view-only: report their state, and if asked to operate one, say briefly you're not " <>
      "set up for that. Use home_status for questions about state. Colors: set_color with a color " <>
      "name or hex; \"warmer\"/\"cooler\" is set_color_temp with warm/cool. To play music use " <>
      "play_music (what to play, and the room or speaker if named); to pause, skip or change " <>
      "volume, use home_control on that speaker."
  end

  @impl true
  # No call to the live client and no copy of the house: the names are a :persistent_term read.
  def wants?(text, _ctx) do
    padded = " " <> Phrases.normalize(text) <> " "
    Enum.any?(@generic ++ HomeAssistant.phrases(), &String.contains?(padded, " " <> &1 <> " "))
  end
end
