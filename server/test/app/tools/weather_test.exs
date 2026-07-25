defmodule App.Tools.WeatherTest do
  # async: false — sets a global Req test plug via application env.
  use ExUnit.Case, async: false

  alias App.Tools.Weather

  test "code_phrase maps known WMO codes and falls back" do
    assert Weather.code_phrase(0) == "clear"
    assert Weather.code_phrase(61) == "rain"
    assert Weather.code_phrase(999) == "unsettled"
  end

  test "build_result assembles the location + current + hourly + daily bundle" do
    fc = %{
      "current" => %{
        "time" => "2026-06-19T15:00",
        "temperature_2m" => 70.0,
        "apparent_temperature" => 68.0,
        "relative_humidity_2m" => 50,
        "weather_code" => 61,
        "wind_speed_10m" => 8.0,
        "wind_gusts_10m" => 17.0,
        "wind_direction_10m" => 315,
        "precipitation" => 0.1,
        "cloud_cover" => 75,
        "visibility" => 16093,
        "uv_index" => 4.0,
        "is_day" => 1
      },
      "hourly" => %{
        "time" => ["2026-06-19T15:00", "2026-06-19T16:00"],
        "temperature_2m" => [70.0, 71.0],
        "precipitation_probability" => [40, 30],
        "weather_code" => [61, 2],
        "wind_speed_10m" => [8.0, 9.0],
        "wind_gusts_10m" => [17.0, 18.0]
      },
      "daily" => %{
        "time" => ["2026-06-19"],
        "weather_code" => [61],
        "temperature_2m_max" => [75.0],
        "temperature_2m_min" => [60.0],
        "precipitation_probability_max" => [60],
        "wind_speed_10m_max" => [12.0],
        "wind_gusts_10m_max" => [24.0],
        "uv_index_max" => [5.0],
        "sunrise" => ["2026-06-19T05:34"],
        "sunset" => ["2026-06-19T20:26"]
      }
    }

    result = Weather.build_result("Belleville, IL", fc)

    assert result.location == "Belleville, IL"
    assert result.current.conditions == "rain"
    assert result.current.wind_dir == "NW"
    assert length(result.hourly) == 2
    assert hd(result.hourly).precip_chance == 40
    assert [day] = result.daily
    assert day.high_f == 75
    assert day.gust_mph_max == 24
  end

  test "build_result with no current block returns an error shape" do
    assert Weather.build_result("X", %{}) == %{location: "X", error: "no data"}
  end

  test "degrees_to_cardinal maps degrees to 16-point compass" do
    assert Weather.degrees_to_cardinal(0) == "N"
    assert Weather.degrees_to_cardinal(90) == "E"
    assert Weather.degrees_to_cardinal(180) == "S"
    assert Weather.degrees_to_cardinal(270) == "W"
    assert Weather.degrees_to_cardinal(315) == "NW"
    assert Weather.degrees_to_cardinal(360) == "N"
    assert Weather.degrees_to_cardinal(nil) == nil
  end

  test "meters_to_miles converts and rounds to one decimal" do
    assert Weather.meters_to_miles(16093) == 10.0
    assert Weather.meters_to_miles(0) == 0.0
    assert Weather.meters_to_miles(nil) == nil
  end

  test "code_phrase covers the new freezing/snow/thunderstorm codes" do
    assert Weather.code_phrase(56) == "freezing drizzle"
    assert Weather.code_phrase(66) == "freezing rain"
    assert Weather.code_phrase(77) == "snow grains"
    assert Weather.code_phrase(85) == "snow showers"
    assert Weather.code_phrase(99) == "thunderstorm with hail"
  end

  test "build_current shapes the Open-Meteo current block" do
    cur = %{
      "time" => "2026-06-19T15:00",
      "temperature_2m" => 71.2,
      "apparent_temperature" => 69.1,
      "relative_humidity_2m" => 54,
      "weather_code" => 2,
      "wind_speed_10m" => 8.3,
      "wind_gusts_10m" => 17.4,
      "wind_direction_10m" => 315,
      "precipitation" => 0.0,
      "cloud_cover" => 40,
      "visibility" => 16093,
      "uv_index" => 5.1,
      "is_day" => 1
    }

    assert Weather.build_current(cur) == %{
             temp_f: 71,
             feels_like_f: 69,
             humidity: 54,
             conditions: "partly cloudy",
             wind_mph: 8,
             gust_mph: 17,
             wind_dir: "NW",
             precip_in: 0.0,
             cloud_pct: 40,
             visibility_mi: 10.0,
             uv: 5,
             is_day: true
           }
  end

  test "build_current degrades to nil fields on an empty block, never crashes" do
    assert Weather.build_current(%{}) == %{
             temp_f: nil,
             feels_like_f: nil,
             humidity: nil,
             conditions: "unsettled",
             wind_mph: nil,
             gust_mph: nil,
             wind_dir: nil,
             precip_in: nil,
             cloud_pct: nil,
             visibility_mi: nil,
             uv: nil,
             is_day: nil
           }
  end

  test "build_hourly zips parallel arrays and slices the next 12 from now" do
    hourly = %{
      "time" => ["2026-06-19T13:00", "2026-06-19T14:00", "2026-06-19T15:00", "2026-06-19T16:00"],
      "temperature_2m" => [68.0, 70.0, 72.0, 73.0],
      "precipitation_probability" => [0, 5, 10, 20],
      "weather_code" => [1, 2, 2, 61],
      "wind_speed_10m" => [6.0, 7.0, 9.0, 10.0],
      "wind_gusts_10m" => [12.0, 14.0, 18.0, 20.0]
    }

    result = Weather.build_hourly(hourly, "2026-06-19T15:00")

    assert length(result) == 2

    assert hd(result) == %{
             time: "2026-06-19T15:00",
             temp_f: 72,
             precip_chance: 10,
             conditions: "partly cloudy",
             wind_mph: 9,
             gust_mph: 18
           }

    assert List.last(result).conditions == "rain"
  end

  test "build_hourly caps at 12 entries and tolerates empty input" do
    times = for h <- 0..23, do: "2026-06-19T#{String.pad_leading("#{h}", 2, "0")}:00"
    arr = fn -> for _ <- 0..23, do: 0 end

    hourly = %{
      "time" => times,
      "temperature_2m" => arr.(),
      "precipitation_probability" => arr.(),
      "weather_code" => arr.(),
      "wind_speed_10m" => arr.(),
      "wind_gusts_10m" => arr.()
    }

    assert length(Weather.build_hourly(hourly, "2026-06-19T00:00")) == 12
    assert Weather.build_hourly(%{}, "2026-06-19T00:00") == []
  end

  test "build_daily zips the daily arrays into day maps" do
    daily = %{
      "time" => ["2026-06-19", "2026-06-20"],
      "weather_code" => [2, 61],
      "temperature_2m_max" => [78.4, 74.0],
      "temperature_2m_min" => [61.2, 59.0],
      "precipitation_probability_max" => [20, 80],
      "wind_speed_10m_max" => [12.0, 15.0],
      "wind_gusts_10m_max" => [24.0, 30.0],
      "uv_index_max" => [6.0, 4.0],
      "sunrise" => ["2026-06-19T05:34", "2026-06-20T05:34"],
      "sunset" => ["2026-06-19T20:26", "2026-06-20T20:27"]
    }

    assert [today, tomorrow] = Weather.build_daily(daily)

    assert today == %{
             date: "2026-06-19",
             conditions: "partly cloudy",
             high_f: 78,
             low_f: 61,
             precip_chance: 20,
             wind_mph_max: 12,
             gust_mph_max: 24,
             uv_max: 6,
             sunrise: "2026-06-19T05:34",
             sunset: "2026-06-19T20:26"
           }

    assert tomorrow.conditions == "rain"
    assert tomorrow.precip_chance == 80
  end

  test "execute fetches the forecast for home and returns the bundle" do
    Application.put_env(:app, :weather_req_opts, plug: {Req.Test, WeatherStub})
    on_exit(fn -> Application.delete_env(:app, :weather_req_opts) end)

    Req.Test.stub(WeatherStub, fn conn ->
      Req.Test.json(conn, %{
        "current" => %{
          "time" => "2026-06-19T15:00",
          "temperature_2m" => 70.0,
          "apparent_temperature" => 68.0,
          "relative_humidity_2m" => 50,
          "weather_code" => 2,
          "wind_speed_10m" => 8.0,
          "wind_gusts_10m" => 17.0,
          "wind_direction_10m" => 315,
          "precipitation" => 0.0,
          "cloud_cover" => 40,
          "visibility" => 16093,
          "uv_index" => 5.0,
          "is_day" => 1
        },
        "hourly" => %{
          "time" => ["2026-06-19T15:00"],
          "temperature_2m" => [70.0],
          "precipitation_probability" => [10],
          "weather_code" => [2],
          "wind_speed_10m" => [8.0],
          "wind_gusts_10m" => [17.0]
        },
        "daily" => %{
          "time" => ["2026-06-19"],
          "weather_code" => [2],
          "temperature_2m_max" => [75.0],
          "temperature_2m_min" => [60.0],
          "precipitation_probability_max" => [20],
          "wind_speed_10m_max" => [12.0],
          "wind_gusts_10m_max" => [24.0],
          "uv_index_max" => [5.0],
          "sunrise" => ["2026-06-19T05:34"],
          "sunset" => ["2026-06-19T20:26"]
        }
      })
    end)

    ctx = %{session_id: "default", config: App.Config.default()}
    assert {:ok, r} = Weather.execute("get_weather", %{}, ctx)
    assert r.location == "Belleville, IL"
    assert r.current.temp_f == 70
    assert r.current.conditions == "partly cloudy"
    assert length(r.hourly) == 1
    assert [_day] = r.daily
  end
end
