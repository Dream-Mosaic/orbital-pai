defmodule App.GlanceTest do
  # async: false — tools run under the shared App.Conversations.TaskSup.
  use ExUnit.Case, async: false

  alias App.Config

  # Saturday Oct 10 2026, 2:00 PM in America/Chicago (CDT, UTC-5).
  @now ~U[2026-10-10 19:00:00Z]
  @tz "America/Chicago"

  defmodule FakeWeather do
    @behaviour App.Tools.Tool
    def declarations,
      do: [%{name: "get_weather", description: "w", parameters: %{type: "object"}}]

    def execute("get_weather", _args, _ctx) do
      case :persistent_term.get({__MODULE__, :mode}, :ok) do
        :ok ->
          {:ok,
           App.Tools.Weather.build_result("Belleville, IL", %{
             "current" => %{
               "time" => "2026-10-10T14:00",
               "temperature_2m" => 63.6,
               "apparent_temperature" => 62.0,
               "relative_humidity_2m" => 48,
               "weather_code" => 2,
               "wind_speed_10m" => 8.3,
               "wind_gusts_10m" => 17.0,
               "wind_direction_10m" => 190,
               "precipitation" => 0.0,
               "cloud_cover" => 40,
               "visibility" => 16_093,
               "uv_index" => 4.0,
               "is_day" => 1
             },
             "daily" => %{
               "time" => ["2026-10-10"],
               "weather_code" => [2],
               "temperature_2m_max" => [71.0],
               "temperature_2m_min" => [52.0],
               "precipitation_probability_max" => [10],
               "wind_speed_10m_max" => [12.0],
               "wind_gusts_10m_max" => [24.0],
               "uv_index_max" => [5.0],
               "sunrise" => ["2026-10-10T07:05"],
               "sunset" => ["2026-10-10T18:31"]
             }
           })}

        :down ->
          {:error, :timeout}
      end
    end
  end

  defmodule FakeCalendar do
    @behaviour App.Tools.Tool
    def declarations,
      do: [%{name: "get_calendar_events", description: "c", parameters: %{type: "object"}}]

    def execute("get_calendar_events", _args, _ctx),
      do: {:ok, %{events: :persistent_term.get({__MODULE__, :events}, [])}}
  end

  setup do
    on_exit(fn ->
      :persistent_term.erase({FakeWeather, :mode})
      :persistent_term.erase({FakeCalendar, :events})
    end)

    %{config: %Config{tools: [FakeWeather, FakeCalendar], tool_cache: false}}
  end

  defp build(config), do: App.Glance.build(1, config: config, now: @now, tz: @tz)

  test "weather + the next TIMED event, display-ready", %{config: config} do
    :persistent_term.put({FakeCalendar, :events}, [
      # already started — not "next"
      %{summary: "Lunch", start: "2026-10-10T17:00:00Z", all_day?: false},
      # all-day — never "next" on a clock face
      %{summary: "Mom's birthday", start: "2026-10-10", all_day?: true},
      %{summary: "Dinner with Mom", start: "2026-10-11T00:30:00Z", all_day?: false},
      %{summary: "Dentist", start: "2026-10-11T14:00:00Z", all_day?: false}
    ])

    assert %{
             weather: %{temp: "64°", condition: condition, icon: icon},
             next_event: %{title: "Dinner with Mom", time: "7:30 PM", day: "Today"}
           } = build(config)

    assert is_binary(condition) and condition != ""
    assert is_binary(icon) and icon != ""
  end

  test "tomorrow's first event is labelled Tomorrow", %{config: config} do
    :persistent_term.put({FakeCalendar, :events}, [
      %{summary: "Dentist", start: "2026-10-11T14:00:00Z", all_day?: false}
    ])

    assert %{next_event: %{title: "Dentist", time: "9:00 AM", day: "Tomorrow"}} = build(config)
  end

  test "each half degrades on its own: no events, weather down", %{config: config} do
    :persistent_term.put({FakeWeather, :mode}, :down)
    assert build(config) == %{weather: nil, next_event: nil}
  end
end
