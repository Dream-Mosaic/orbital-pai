defmodule App.Toolkits.Home do
  @moduledoc "The house (Home Assistant) as a toolkit: home_control, home_status, play_music."
  @behaviour App.Toolkits.Toolkit

  alias App.HomeAssistant.Directory

  @generic ~w(light lights lamp lamps switch plug outlet fan fans thermostat heat heater ac aircon
              blinds shades curtains fireplace music song songs playlist album speaker speakers
              volume tv television scene nightlight dim brighter darker garage lock unlock alarm) ++
             ["turn on", "turn off", "switch on", "switch off", "air conditioning"]
  # trailing device words dropped from an entry name to get its "core" ("Dining table lights")
  @tails ~w(light lights lamp lamps switch plug power)
  @min_len 4

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
  def wants?(text, _ctx) do
    padded = " " <> normalize(text) <> " "
    Enum.any?(phrases(), &String.contains?(padded, " " <> &1 <> " "))
  end

  defp phrases do
    @generic ++ directory_phrases()
  end

  defp directory_phrases do
    case App.HomeAssistant.directory() do
      {:ok, %Directory{} = dir} ->
        names =
          Directory.entries(dir)
          |> Enum.flat_map(fn e -> [core(e.name) | Enum.map(e.aliases || [], &normalize/1)] end)

        areas = Enum.map(Enum.map(dir.areas, &area_name/1), &normalize/1)

        (names ++ areas)
        |> Enum.filter(&(String.length(&1) >= @min_len and &1 not in @generic))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp area_name(%{"name" => n}), do: n
  defp area_name(%{name: n}), do: n
  defp area_name(n) when is_binary(n), do: n
  defp area_name(_), do: ""

  defp core(nil), do: ""

  defp core(name) do
    name |> normalize() |> String.split(" ", trim: true) |> strip_tails() |> Enum.join(" ")
  end

  defp strip_tails(words) do
    case Enum.reverse(words) do
      [last | rest] when last in @tails and rest != [] -> strip_tails(Enum.reverse(rest))
      _ -> words
    end
  end

  defp normalize(nil), do: ""

  defp normalize(text) do
    text |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, " ") |> String.trim()
  end
end
