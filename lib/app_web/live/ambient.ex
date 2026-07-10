defmodule AppWeb.Ambient do
  @moduledoc """
  Pure formatting helpers for the kiosk ambient info strip.

  Both functions take the raw result map a tool call would produce
  (`App.Tools.Weather.build_result/2` / `App.Tools.Calendar.execute/2` for
  `"get_calendar_events"`) and reduce it to a single display line, or `nil`
  when there's nothing worth showing. No HTTP, no LiveView — callers own
  fetching the tool result and re-rendering on a schedule.
  """

  @doc """
  Formats the current-conditions line from a `get_weather` tool result, e.g.
  `"72° partly cloudy"`.

  Returns `nil` for the error shape (`%{location: _, error: _}`, no
  `:current` key), `nil`, or any map missing a well-formed `:current`.
  """
  @spec weather_line(map() | nil) :: String.t() | nil
  def weather_line(%{current: %{temp_f: temp_f, conditions: conditions}})
      when is_number(temp_f) and is_binary(conditions) do
    "#{round(temp_f)}° #{conditions}"
  end

  def weather_line(_result), do: nil

  @doc """
  Formats the next upcoming event from a `get_calendar_events` tool result as
  `"Next: <summary> <local time>"`, e.g. `"Next: Dinner 6:30pm"`.

  Events are expected pre-sorted by start ascending (as the calendar tool
  returns them); this picks the first one whose `start` both parses as a
  datetime (all-day events have a date-only `start` and are skipped) and is
  at-or-after `now`. Returns `nil` when the result shape doesn't match, there
  are no events, or nothing upcoming remains.
  """
  @spec next_event_line(map() | nil, DateTime.t()) :: String.t() | nil
  def next_event_line(%{events: events}, %DateTime{} = now) when is_list(events) do
    Enum.find_value(events, &upcoming_line(&1, now))
  end

  def next_event_line(_result, _now), do: nil

  defp upcoming_line(%{start: start, summary: summary}, now) when is_binary(start) do
    with {:ok, dt, _offset} <- DateTime.from_iso8601(start),
         false <- DateTime.compare(dt, now) == :lt do
      "Next: #{summary} #{local_time(dt)}"
    else
      _ -> nil
    end
  end

  defp upcoming_line(_event, _now), do: nil

  defp local_time(dt) do
    dt
    |> DateTime.shift_zone!(App.Config.default().timezone)
    |> Calendar.strftime("%-I:%M%P")
  end
end
