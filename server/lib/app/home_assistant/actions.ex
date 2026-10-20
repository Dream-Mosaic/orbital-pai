defmodule App.HomeAssistant.Actions do
  @moduledoc """
  Pure planner: `(raw HA state, action, params)` → the ONE service call to make. No I/O.

  The color-ish actions (`set_color`, `set_color_temp`, `set_effect`) need the light's own
  attributes (supported modes, kelvin range, effect list), so they live here. Everything else
  delegates to `Entities.service_for/3`, which keeps the safety table (no lock / alarm / garage
  mapping, anywhere) in exactly one place. The color actions are gated on
  `Entities.classify/1 == :controllable` and the `light` domain before anything else is looked at.

  Model-supplied values arrive loosely typed ("50", "#F80", " Blue "), so they are normalized here.
  """

  alias App.HomeAssistant.Entities

  @actions ~w(on off toggle set_brightness brighten dim set_color set_color_temp set_effect set_temperature set_position open close set_speed volume_set play pause next activate)

  @color_modes ~w(hs xy rgb rgbw rgbww)

  @colors %{
    "red" => [255, 0, 0],
    "orange" => [255, 136, 0],
    "yellow" => [255, 255, 0],
    "green" => [0, 255, 0],
    "blue" => [0, 0, 255],
    "purple" => [128, 0, 128],
    "pink" => [255, 105, 180],
    "white" => [255, 255, 255],
    "warm white" => [255, 190, 110],
    "cyan" => [0, 255, 255],
    "teal" => [0, 128, 128],
    "magenta" => [255, 0, 255],
    "lavender" => [180, 150, 255],
    "gold" => [255, 200, 0],
    "lime" => [160, 255, 0],
    "amber" => [255, 160, 0]
  }

  @temps %{"warm" => 2700, "soft" => 3000, "neutral" => 4000, "cool" => 5000, "daylight" => 6500}

  @type reason ::
          :not_controllable
          | :unknown_action
          | :needs_value
          | :no_color_support
          | :no_color_temp_support
          | :no_effects
          | {:unknown_color, String.t()}
          | {:unknown_effect, [String.t()]}

  @doc "The closed action vocabulary the brain may use."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @spec plan(map(), String.t(), map()) ::
          {:ok, {String.t(), String.t(), map()}} | {:error, reason()}
  def plan(raw, action, params \\ %{})

  def plan(raw, action, params) when action in ["set_color", "set_color_temp", "set_effect"] do
    cond do
      Entities.classify(raw) != :controllable or Entities.domain(raw) != "light" ->
        {:error, :not_controllable}

      true ->
        color_action(action, raw["attributes"] || %{}, params)
    end
  end

  def plan(raw, action, params), do: Entities.service_for(raw, action, number(params[:value]))

  # -- set_color --

  defp color_action("set_color", attrs, params) do
    cond do
      not Enum.any?(modes(attrs), &(&1 in @color_modes)) -> {:error, :no_color_support}
      blank?(params[:color]) -> {:error, :needs_value}
      true -> with {:ok, rgb} <- parse_color(params[:color]), do: turn_on(%{rgb_color: rgb})
    end
  end

  # -- set_color_temp --

  defp color_action("set_color_temp", attrs, params) do
    kelvin = temp_kelvin(params)

    cond do
      "color_temp" not in modes(attrs) -> {:error, :no_color_temp_support}
      is_nil(kelvin) -> {:error, :needs_value}
      true -> turn_on(%{color_temp_kelvin: clamp_kelvin(kelvin, attrs)})
    end
  end

  # -- set_effect --

  defp color_action("set_effect", attrs, params) do
    case attrs["effect_list"] do
      [_ | _] = list ->
        if blank?(params[:effect]),
          do: {:error, :needs_value},
          else: match_effect(list, params[:effect])

      _ ->
        {:error, :no_effects}
    end
  end

  defp turn_on(data), do: {:ok, {"light", "turn_on", data}}

  defp modes(attrs), do: List.wrap(attrs["supported_color_modes"])

  defp parse_color(input) do
    c = input |> String.trim() |> String.downcase()

    cond do
      rgb = @colors[c] -> {:ok, rgb}
      rgb = hex(c) -> {:ok, rgb}
      true -> {:error, {:unknown_color, String.trim(input)}}
    end
  end

  defp hex("#" <> h), do: hex(h)

  defp hex(<<r, g, b>> = h) do
    if hex?(h), do: Enum.map([r, g, b], &String.to_integer(<<&1, &1>>, 16))
  end

  defp hex(<<_::binary-size(6)>> = h) do
    if hex?(h) do
      for <<pair::binary-size(2) <- h>>, do: String.to_integer(pair, 16)
    end
  end

  defp hex(_), do: nil

  defp hex?(h), do: Regex.match?(~r/\A[0-9a-f]+\z/, h)

  defp temp_kelvin(params) do
    case number(params[:value]) do
      v when is_number(v) ->
        round(v)

      nil ->
        with c when is_binary(c) <- params[:color],
             do: @temps[c |> String.trim() |> String.downcase()]
    end
  end

  defp clamp_kelvin(k, attrs) do
    k
    |> then(fn k ->
      if is_number(attrs["min_color_temp_kelvin"]),
        do: max(k, attrs["min_color_temp_kelvin"]),
        else: k
    end)
    |> then(fn k ->
      if is_number(attrs["max_color_temp_kelvin"]),
        do: min(k, attrs["max_color_temp_kelvin"]),
        else: k
    end)
  end

  # Exact (case-insensitive), then ignoring spaces, then fuzzy (>= 0.85).
  defp match_effect(list, wanted) do
    w = wanted |> String.trim() |> String.downcase()
    squash = &String.replace(&1, ~r/[\s_-]+/, "")

    found =
      Enum.find(list, &(String.downcase(&1) == w)) ||
        Enum.find(list, &(squash.(String.downcase(&1)) == squash.(w))) ||
        fuzzy(list, squash.(w), squash)

    if found, do: turn_on(%{effect: found}), else: {:error, {:unknown_effect, list}}
  end

  defp fuzzy(list, w, squash) do
    {best, score} =
      list
      |> Enum.map(&{&1, String.jaro_distance(squash.(String.downcase(&1)), w)})
      |> Enum.max_by(&elem(&1, 1))

    if score >= 0.85, do: best
  end

  defp blank?(s), do: not is_binary(s) or String.trim(s) == ""

  # Accept numbers or numeric strings; anything else is "no value".
  defp number(v) when is_number(v), do: v

  defp number(v) when is_binary(v) do
    case Float.parse(String.trim(v)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp number(_), do: nil
end
