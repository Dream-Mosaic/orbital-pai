defmodule App.GlanceTest do
  # async: false — tools run under the shared App.Conversations.TaskSup, and the reminders part
  # reads the (shared-sandbox) database from a task.
  use App.DataCase, async: false

  alias App.Config
  alias App.Reminders
  alias App.Users

  # Saturday Oct 10 2026, 2:00 PM in America/Chicago (CDT, UTC-5).
  @now ~U[2026-10-10 19:00:00Z]
  @tz "America/Chicago"

  defmodule FakeWeather do
    @behaviour App.Tools.Tool
    def declarations,
      do: [%{name: "get_weather", description: "w", parameters: %{type: "object"}}]

    def execute("get_weather", _args, _ctx) do
      :persistent_term.put(
        {__MODULE__, :calls},
        :persistent_term.get({__MODULE__, :calls}, 0) + 1
      )

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
             "hourly" => hourly(),
             "daily" => daily()
           })}

        :down ->
          {:error, :timeout}
      end
    end

    # 1 PM .. 11 PM local; the tool starts its outlook at the current hour (2 PM).
    defp hourly do
      %{
        "time" => Enum.map(13..23, &"2026-10-10T#{&1}:00"),
        "temperature_2m" => Enum.map(13..23, &(77.0 - &1)),
        "precipitation_probability" => List.duplicate(0, 11),
        "weather_code" => List.duplicate(2, 11),
        "wind_speed_10m" => List.duplicate(5.0, 11),
        "wind_gusts_10m" => List.duplicate(9.0, 11)
      }
    end

    # Sat Oct 10 (today: the headline's hi/lo, as before) through Fri Oct 16.
    defp daily do
      days = Enum.map(10..16, &"2026-10-#{&1}")

      %{
        "time" => days,
        "weather_code" => [2 | List.duplicate(0, 6)],
        "temperature_2m_max" => [71.0 | List.duplicate(68.0, 6)],
        "temperature_2m_min" => [52.0 | List.duplicate(50.0, 6)],
        "precipitation_probability_max" => List.duplicate(10, 7),
        "wind_speed_10m_max" => List.duplicate(12.0, 7),
        "wind_gusts_10m_max" => List.duplicate(24.0, 7),
        "uv_index_max" => List.duplicate(5.0, 7),
        "sunrise" => Enum.map(days, &"#{&1}T07:05"),
        "sunset" => Enum.map(days, &"#{&1}T18:31")
      }
    end
  end

  defmodule FakeCalendar do
    @behaviour App.Tools.Tool
    def declarations,
      do: [%{name: "get_calendar_events", description: "c", parameters: %{type: "object"}}]

    def execute("get_calendar_events", _args, _ctx) do
      :persistent_term.put(
        {__MODULE__, :calls},
        :persistent_term.get({__MODULE__, :calls}, 0) + 1
      )

      case :persistent_term.get({__MODULE__, :mode}, :ok) do
        :ok -> {:ok, %{events: :persistent_term.get({__MODULE__, :events}, [])}}
        :down -> {:error, :timeout}
      end
    end
  end

  setup do
    on_exit(fn ->
      for mod <- [FakeWeather, FakeCalendar],
          key <- [:mode, :events, :calls],
          do: :persistent_term.erase({mod, key})
    end)

    %{config: %Config{tools: [FakeWeather, FakeCalendar], tool_cache: false}}
  end

  defp build(config), do: App.Glance.build(1, config: config, now: @now, tz: @tz)
  defp build(config, uid), do: App.Glance.build(uid, config: config, now: @now, tz: @tz)

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
             next_event: %{
               title: "Dinner with Mom",
               time: "7:30 PM",
               day: "Today",
               at: "2026-10-11T00:30:00Z"
             }
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

    assert build(config) == %{
             weather: nil,
             next_event: nil,
             agenda: [],
             forecast: nil,
             reminders: []
           }
  end

  describe "agenda" do
    test "today and tomorrow, timed and all-day, in start order, capped at 6", %{config: config} do
      :persistent_term.put({FakeCalendar, :events}, [
        # ended at 1 PM — gone
        %{
          summary: "Lunch",
          start: "2026-10-10T17:00:00Z",
          end: "2026-10-10T18:00:00Z",
          all_day?: false
        },
        # in progress (1–3 PM): stays until it ends
        %{
          summary: "Poke the Brain",
          start: "2026-10-10T13:00:00-05:00",
          end: "2026-10-10T15:00:00-05:00",
          all_day?: false
        },
        # all-day yesterday (end date is exclusive) — over
        %{summary: "Conference", start: "2026-10-09", end: "2026-10-10", all_day?: true},
        # multi-day, began yesterday: still on today
        %{summary: "Trip", start: "2026-10-09", end: "2026-10-13", all_day?: true},
        %{summary: "Mom's birthday", start: "2026-10-10", end: "2026-10-11", all_day?: true},
        %{
          summary: "Dinner with Mom",
          start: "2026-10-11T00:30:00Z",
          end: "2026-10-11T02:00:00Z",
          all_day?: false
        },
        %{
          summary: "Dentist",
          start: "2026-10-11T14:00:00Z",
          end: "2026-10-11T15:00:00Z",
          all_day?: false
        },
        %{summary: "Farmers market", start: "2026-10-11", end: "2026-10-12", all_day?: true},
        # the 7th upcoming one — past the cap
        %{
          summary: "Brunch",
          start: "2026-10-11T17:00:00Z",
          end: "2026-10-11T18:00:00Z",
          all_day?: false
        },
        # Monday — past the end of tomorrow
        %{
          summary: "Standup",
          start: "2026-10-12T14:00:00Z",
          end: "2026-10-12T14:15:00Z",
          all_day?: false
        },
        %{summary: "Garbage day", start: "2026-10-12", end: "2026-10-13", all_day?: true}
      ])

      assert build(config).agenda == [
               %{title: "Trip", time: "All day", day: "Today", all_day: true, at: nil},
               %{title: "Mom's birthday", time: "All day", day: "Today", all_day: true, at: nil},
               %{
                 title: "Poke the Brain",
                 time: "1:00 PM",
                 day: "Today",
                 all_day: false,
                 at: "2026-10-10T18:00:00Z"
               },
               %{
                 title: "Dinner with Mom",
                 time: "7:30 PM",
                 day: "Today",
                 all_day: false,
                 at: "2026-10-11T00:30:00Z"
               },
               %{
                 title: "Farmers market",
                 time: "All day",
                 day: "Tomorrow",
                 all_day: true,
                 at: nil
               },
               %{
                 title: "Dentist",
                 time: "9:00 AM",
                 day: "Tomorrow",
                 all_day: false,
                 at: "2026-10-11T14:00:00Z"
               }
             ]
    end

    test "with no end, a timed event stays until it starts", %{config: config} do
      :persistent_term.put({FakeCalendar, :events}, [
        %{summary: "Started", start: "2026-10-10T18:30:00Z", all_day?: false},
        %{summary: "Later", start: "2026-10-10T22:00:00Z", all_day?: false}
      ])

      assert [%{title: "Later", time: "5:00 PM"}] = build(config).agenda
    end

    test "one calendar read serves next_event and agenda", %{config: config} do
      :persistent_term.put({FakeCalendar, :events}, [
        %{summary: "Dentist", start: "2026-10-11T14:00:00Z", all_day?: false}
      ])

      assert %{next_event: %{title: "Dentist"}, agenda: [%{title: "Dentist"}]} = build(config)
      assert :persistent_term.get({FakeCalendar, :calls}) == 1
    end

    test "a malformed event is skipped, not fatal", %{config: config} do
      :persistent_term.put({FakeCalendar, :events}, [
        %{summary: "Broken", start: nil, all_day?: false},
        %{summary: "Bad date", start: "someday", all_day?: true},
        %{summary: "Dentist", start: "2026-10-11T14:00:00Z", all_day?: false}
      ])

      assert [%{title: "Dentist"}] = build(config).agenda
    end
  end

  describe "forecast" do
    test "the weather card's next 6 hours and 3 days", %{config: config} do
      assert %{forecast: %{hourly: hourly, daily: daily}} = build(config)

      assert Enum.map(hourly, & &1.label) == ["2PM", "3PM", "4PM", "5PM", "6PM", "7PM"]
      assert %{temp: "63°", icon: "partly", condition: "Partly cloudy"} = hd(hourly)

      assert Enum.map(daily, & &1.label) == ["Sun", "Mon", "Tue"]
      assert %{hi: "68°", lo: "50°", icon: "clear"} = hd(daily)
    end

    test "one weather read serves weather and forecast", %{config: config} do
      assert %{weather: %{temp: "64°"}, forecast: %{}} = build(config)
      assert :persistent_term.get({FakeWeather, :calls}) == 1
    end
  end

  describe "reminders" do
    setup do
      Application.put_env(:app, :allowed_users, [
        %{email: "d@x.com", name: "Alice"},
        %{email: "t@x.com", name: "Bob"}
      ])

      on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
      {:ok, d} = Users.upsert_allowed("d@x.com")
      {:ok, t} = Users.upsert_allowed("t@x.com")
      %{d: d.id, t: t.id}
    end

    defp remind(uid, body, due_at, extra \\ %{}) do
      {:ok, r} = Reminders.create(Map.merge(%{user_id: uid, body: body, due_at: due_at}, extra))
      r
    end

    test "today's pending ones, own and household, soonest first", %{config: c, d: d, t: t} do
      remind(t, "take out the bins", ~U[2026-10-11 01:00:00Z], %{household: true})
      remind(d, "call the vet", ~U[2026-10-10 21:00:00Z])
      # another member's personal reminder — not ours
      remind(t, "their thing", ~U[2026-10-10 20:00:00Z])
      # already fired
      remind(d, "fired", ~U[2026-10-10 22:00:00Z], %{fired_at: ~U[2026-10-10 18:00:00Z]})
      # earlier today: already past
      remind(d, "past", ~U[2026-10-10 18:30:00Z])
      # tomorrow (local) — not today's
      remind(d, "tomorrow", ~U[2026-10-11 14:00:00Z])

      assert build(c, d).reminders == [
               %{text: "Call the vet", time: "4:00 PM", household: false},
               %{text: "Take out the bins", time: "8:00 PM", household: true}
             ]
    end

    test "capped at 5", %{config: c, d: d} do
      for h <- 20..23, do: remind(d, "r#{h}", DateTime.new!(~D[2026-10-10], Time.new!(h, 0, 0)))
      for h <- 0..2, do: remind(d, "s#{h}", DateTime.new!(~D[2026-10-11], Time.new!(h, 0, 0)))

      assert Enum.map(build(c, d).reminders, & &1.text) == ["R20", "R21", "R22", "R23", "S0"]
    end

    test "a calendar outage keeps forecast and reminders", %{config: c, d: d} do
      :persistent_term.put({FakeCalendar, :mode}, :down)
      remind(d, "call the vet", ~U[2026-10-10 21:00:00Z])

      assert %{
               weather: %{temp: "64°"},
               next_event: nil,
               agenda: [],
               forecast: %{hourly: [_ | _], daily: [_ | _]},
               reminders: [%{text: "Call the vet"}]
             } = build(c, d)
    end
  end
end
