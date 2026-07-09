defmodule App.Tools.Weather do
  @moduledoc """
  Weather via Open-Meteo (keyless, free). One `get_weather` call returns a rich bundle: current
  conditions (temp, feels-like, humidity, wind + gusts, precip, cloud, visibility, UV, is-day),
  a next-~12h hourly outlook, and a 7-day daily forecast — US units. Pure shaping helpers
  (`build_current/1`, `build_hourly/2`, `build_daily/1`) keep it testable; the brain reasons
  about activity suitability ("can I fly drones?") from the data.
  """
  @behaviour App.Tools.Tool

  @geo_url "https://geocoding-api.open-meteo.com/v1/search"
  @forecast_url "https://api.open-meteo.com/v1/forecast"

  @impl true
  def declarations do
    [
      %{
        name: "get_weather",
        description:
          "Current conditions, an hourly outlook (next ~12h), and a 7-day forecast for a US " <>
            "location: temperature, feels-like, humidity, wind and gusts, precipitation chance, " <>
            "cloud cover, visibility, UV, sunrise/sunset. Use wind/gusts/precip/visibility to " <>
            "judge activity suitability when asked (e.g. flying drones). Defaults to the user's " <>
            "home (Belleville, IL) when no location is given.",
        parameters: %{
          type: "object",
          properties: %{
            location: %{type: "string", description: "City and state or ZIP; omit for home."}
          },
          required: []
        }
      }
    ]
  end

  @impl true
  def cache_ttl("get_weather"), do: 300_000
  def cache_ttl(_), do: nil

  @impl true
  def bridge("get_weather"),
    do: [
      "Let me check the weather.",
      "One sec, checking the forecast.",
      "Pulling up the weather now."
    ]

  def bridge(_), do: []

  @impl true
  def execute("get_weather", args, ctx) do
    {lat, lon, label} = resolve(Map.get(args, "location"), ctx)

    case forecast(lat, lon) do
      {:ok, %{"current" => _} = fc} -> {:ok, build_result(label, fc)}
      {:ok, _} -> {:error, :no_data}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---- location ----
  defp resolve(nil, ctx), do: home(ctx)
  defp resolve("", ctx), do: home(ctx)

  defp resolve(loc, ctx) do
    if String.trim(loc) in ["62221", "Belleville", "Belleville, IL", "home"],
      do: home(ctx),
      else: geocode(loc) || home(ctx)
  end

  defp home(%{config: %{weather_home: {lat, lon, label}}}), do: {lat, lon, label}
  defp home(_), do: {38.52, -89.98, "Belleville, IL"}

  defp geocode(loc) do
    case req(@geo_url, name: loc, count: 1) do
      {:ok, %{"results" => [%{"latitude" => lat, "longitude" => lon} = r | _]}} ->
        {lat, lon, r["name"] || loc}

      _ ->
        nil
    end
  end

  # ---- forecast + shaping ----
  defp forecast(lat, lon) do
    req(@forecast_url,
      latitude: lat,
      longitude: lon,
      temperature_unit: "fahrenheit",
      wind_speed_unit: "mph",
      precipitation_unit: "inch",
      timezone: "auto",
      forecast_days: 7,
      current:
        "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m," <>
          "wind_gusts_10m,wind_direction_10m,precipitation,cloud_cover,visibility,uv_index,is_day",
      hourly:
        "temperature_2m,precipitation_probability,weather_code,wind_speed_10m,wind_gusts_10m",
      daily:
        "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max," <>
          "wind_speed_10m_max,wind_gusts_10m_max,uv_index_max,sunrise,sunset"
    )
  end

  @doc false
  def build_result(label, %{"current" => cur} = fc) do
    %{
      location: label,
      current: build_current(cur),
      hourly: build_hourly(Map.get(fc, "hourly", %{}), cur["time"]),
      daily: build_daily(Map.get(fc, "daily", %{}))
    }
  end

  def build_result(label, _other), do: %{location: label, error: "no data"}

  defp round_f(nil), do: nil
  defp round_f(n) when is_number(n), do: round(n)

  defp round_precip(nil), do: nil
  defp round_precip(n) when is_number(n), do: Float.round(n / 1, 2)

  defp req(url, params) do
    opts =
      [params: params, finch: App.Finch, receive_timeout: 5_000] ++
        Application.get_env(:app, :weather_req_opts, [])

    case Req.get(url, opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: s}} -> {:error, {:http, s}}
      {:error, reason} -> {:error, reason}
    end
  end

  # WMO weather interpretation codes → short spoken phrases.
  @codes %{
    0 => "clear",
    1 => "mostly clear",
    2 => "partly cloudy",
    3 => "overcast",
    45 => "fog",
    48 => "fog",
    51 => "light drizzle",
    53 => "drizzle",
    55 => "drizzle",
    61 => "rain",
    63 => "rain",
    65 => "heavy rain",
    71 => "snow",
    73 => "snow",
    75 => "heavy snow",
    56 => "freezing drizzle",
    57 => "freezing drizzle",
    66 => "freezing rain",
    67 => "freezing rain",
    77 => "snow grains",
    80 => "showers",
    81 => "showers",
    82 => "heavy showers",
    85 => "snow showers",
    86 => "heavy snow showers",
    95 => "thunderstorms",
    96 => "thunderstorm with hail",
    99 => "thunderstorm with hail"
  }

  @doc false
  def code_phrase(code), do: Map.get(@codes, code, "unsettled")

  @cardinals ~w(N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW)

  @doc false
  def degrees_to_cardinal(nil), do: nil

  def degrees_to_cardinal(deg) when is_number(deg) do
    idx = (deg / 22.5) |> round() |> Integer.mod(16)
    Enum.at(@cardinals, idx)
  end

  @doc false
  def meters_to_miles(nil), do: nil
  def meters_to_miles(m) when is_number(m), do: Float.round(m / 1609.34, 1)

  @doc false
  def build_daily(d) do
    dates = Map.get(d, "time", [])
    get = fn key -> Map.get(d, key, []) end

    codes = get.("weather_code")
    highs = get.("temperature_2m_max")
    lows = get.("temperature_2m_min")
    pops = get.("precipitation_probability_max")
    winds = get.("wind_speed_10m_max")
    gusts = get.("wind_gusts_10m_max")
    uvs = get.("uv_index_max")
    sunrises = get.("sunrise")
    sunsets = get.("sunset")

    Enum.with_index(dates, fn date, i ->
      %{
        date: date,
        conditions: code_phrase(Enum.at(codes, i)),
        high_f: round_f(Enum.at(highs, i)),
        low_f: round_f(Enum.at(lows, i)),
        precip_chance: round_f(Enum.at(pops, i)),
        wind_mph_max: round_f(Enum.at(winds, i)),
        gust_mph_max: round_f(Enum.at(gusts, i)),
        uv_max: round_f(Enum.at(uvs, i)),
        sunrise: Enum.at(sunrises, i),
        sunset: Enum.at(sunsets, i)
      }
    end)
  end

  @doc false
  # Open-Meteo returns parallel arrays (time[], temperature_2m[], ...). Find the first hour at or
  # after `now_iso` and take 12, zipping the arrays by index. Enum.slice keeps it in-bounds.
  def build_hourly(h, now_iso) do
    times = Map.get(h, "time", [])
    start = Enum.find_index(times, &(&1 >= now_iso)) || 0
    slice = fn key -> h |> Map.get(key, []) |> Enum.slice(start, 12) end

    temps = slice.("temperature_2m")
    pops = slice.("precipitation_probability")
    codes = slice.("weather_code")
    winds = slice.("wind_speed_10m")
    gusts = slice.("wind_gusts_10m")

    times
    |> Enum.slice(start, 12)
    |> Enum.with_index(fn t, i ->
      %{
        time: t,
        temp_f: round_f(Enum.at(temps, i)),
        precip_chance: round_f(Enum.at(pops, i)),
        conditions: code_phrase(Enum.at(codes, i)),
        wind_mph: round_f(Enum.at(winds, i)),
        gust_mph: round_f(Enum.at(gusts, i))
      }
    end)
  end

  @doc false
  def build_current(c) do
    %{
      temp_f: round_f(c["temperature_2m"]),
      feels_like_f: round_f(c["apparent_temperature"]),
      humidity: round_f(c["relative_humidity_2m"]),
      conditions: code_phrase(c["weather_code"]),
      wind_mph: round_f(c["wind_speed_10m"]),
      gust_mph: round_f(c["wind_gusts_10m"]),
      wind_dir: degrees_to_cardinal(c["wind_direction_10m"]),
      precip_in: round_precip(c["precipitation"]),
      cloud_pct: round_f(c["cloud_cover"]),
      visibility_mi: meters_to_miles(c["visibility"]),
      uv: round_f(c["uv_index"]),
      is_day:
        case c["is_day"] do
          1 -> true
          0 -> false
          _ -> nil
        end
    }
  end
end
