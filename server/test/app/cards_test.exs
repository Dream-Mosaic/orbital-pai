defmodule App.CardsTest do
  use ExUnit.Case, async: true

  alias App.Cards

  # Saturday Oct 10 2026, 2:00 PM in America/Chicago (CDT, UTC-5).
  @now ~U[2026-10-10 19:00:00Z]
  @opts [now: @now, tz: "America/Chicago"]

  defp card(name, args, result), do: Cards.from_tool(name, args, result, @opts)

  describe "weather" do
    # Shaped by the tool's own builder from a raw Open-Meteo payload, so this is exactly the
    # map get_weather hands the brain.
    defp weather_result do
      App.Tools.Weather.build_result("Belleville, IL", %{
        "current" => %{
          "time" => "2026-10-10T14:00",
          "temperature_2m" => 71.6,
          "apparent_temperature" => 69.4,
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
        "hourly" => %{
          "time" => for(h <- 14..23, do: "2026-10-10T#{h}:00") ++ ["2026-10-11T00:00"],
          "temperature_2m" => [71.6, 72.4, 71.0, 69.2, 66.0, 63.8, 62.1, 61.0, 60.2, 59.5, 59.0],
          "precipitation_probability" => [5, 10, 25, 60, 70, 15, 5, 0, 0, 0, 0],
          "weather_code" => [2, 2, 3, 61, 95, 2, 0, 0, 0, 0, 0],
          "wind_speed_10m" => [8.3, 9.0, 10.0, 12.0, 11.0, 7.0, 5.0, 4.0, 4.0, 3.0, 3.0],
          "wind_gusts_10m" => [17.0, 18.0, 20.0, 26.0, 24.0, 14.0, 9.0, 8.0, 8.0, 6.0, 6.0]
        },
        "daily" => %{
          "time" => for(d <- 10..16, do: "2026-10-#{d}"),
          "weather_code" => [2, 61, 95, 3, 0, 71, 45],
          "temperature_2m_max" => [78.2, 74.0, 70.5, 66.0, 68.4, 41.0, 55.0],
          "temperature_2m_min" => [61.0, 58.3, 55.0, 49.6, 47.0, 30.2, 40.0],
          "precipitation_probability_max" => [35, 80, 60, 10, 0, 40, 5],
          "wind_speed_10m_max" => [12.0, 14.0, 18.0, 23.0, 9.0, 10.0, 6.0],
          "wind_gusts_10m_max" => [24.0, 28.0, 35.0, 38.0, 15.0, 18.0, 10.0],
          "uv_index_max" => [5.0, 2.0, 1.0, 3.0, 5.0, 2.0, 1.0],
          "sunrise" => for(d <- 10..16, do: "2026-10-#{d}T07:05"),
          "sunset" => for(d <- 10..16, do: "2026-10-#{d}T18:31")
        }
      })
    end

    test "the header is display-ready: temperature, condition, today's range, wind, rain" do
      c = card("get_weather", %{}, weather_result())

      assert c.type == "weather"
      assert c.location == "Belleville, IL"
      assert c.temp == "72°"
      assert c.condition == "Partly cloudy"
      assert c.icon == "partly"
      assert c.hi == "78°"
      assert c.lo == "61°"

      # labelled server-side, so the client renders copy it was sent rather than its own
      assert c.details == [
               %{label: "Feels like", value: "69°"},
               %{label: "Wind", value: "8 mph S"},
               %{label: "Rain", value: "35%"}
             ]
    end

    test "today's chance is shown even when low, and called snow on a snow day" do
      dry =
        weather_result()
        |> put_in([:daily, Access.at(0), :precip_chance], 0)

      assert %{label: "Rain", value: "0%"} in card("get_weather", %{}, dry).details

      snowy =
        weather_result()
        |> put_in([:daily, Access.at(0), :conditions], "snow showers")

      assert %{label: "Snow", value: "35%"} in card("get_weather", %{}, snowy).details
    end

    test "the hourly strip is the next six hours, with night glyphs after sunset" do
      c = card("get_weather", %{}, weather_result())

      assert Enum.map(c.hourly, & &1.label) == ["2PM", "3PM", "4PM", "5PM", "6PM", "7PM"]
      assert Enum.map(c.hourly, & &1.temp) == ["72°", "72°", "71°", "69°", "66°", "64°"]

      assert Enum.map(c.hourly, & &1.icon) ==
               ["partly", "partly", "cloudy", "rain", "storm", "partly_night"]

      # a chance worth showing carries a label; a negligible one is omitted, not "5%"
      assert Enum.map(c.hourly, &Map.get(&1, :precip)) == [nil, nil, "25%", "60%", "70%", nil]
      assert hd(c.hourly).condition == "Partly cloudy"
    end

    test "the daily row is the next five days after today" do
      c = card("get_weather", %{}, weather_result())

      assert Enum.map(c.daily, & &1.label) == ["Sun", "Mon", "Tue", "Wed", "Thu"]
      assert Enum.map(c.daily, & &1.hi) == ["74°", "71°", "66°", "68°", "41°"]
      assert Enum.map(c.daily, & &1.lo) == ["58°", "55°", "50°", "47°", "30°"]
      # Tue is overcast but gusting to 38 — the glyph says wind
      assert Enum.map(c.daily, & &1.icon) == ["rain", "storm", "wind", "clear", "snow"]
      assert Enum.map(c.daily, &Map.get(&1, :precip)) == ["80%", "60%", nil, nil, "40%"]
      assert Enum.at(c.daily, 1).condition == "Thunderstorms"
    end

    test "night variants only exist for clear and partly" do
      assert Cards.weather_icon("clear", false, 0, 0) == "clear_night"
      assert Cards.weather_icon("mostly clear", true, 0, 0) == "clear"
      assert Cards.weather_icon("partly cloudy", false, 0, 0) == "partly_night"
      assert Cards.weather_icon("overcast", false, 0, 0) == "cloudy"
      assert Cards.weather_icon("fog", true, 0, 0) == "fog"
      assert Cards.weather_icon("freezing drizzle", true, 0, 0) == "rain"
      assert Cards.weather_icon("heavy snow showers", true, 0, 0) == "snow"
      assert Cards.weather_icon("thunderstorm with hail", true, 0, 0) == "storm"
      assert Cards.weather_icon("unsettled", true, 0, 0) == "cloudy"
      # wind only overrides a dry sky
      assert Cards.weather_icon("clear", true, 24, 0) == "wind"
      assert Cards.weather_icon("rain", true, 24, 40) == "rain"
    end

    test "an error-shaped result is not a card" do
      assert card("get_weather", %{}, %{location: "X", error: "no data"}) == nil
    end
  end

  describe "agenda" do
    defp event(summary, start, extra \\ %{}) do
      Map.merge(
        %{
          id: summary,
          summary: summary,
          start: start,
          end: start,
          location: nil,
          description: nil,
          attendees: [],
          html_link: "https://calendar.google.com/x",
          all_day?: false,
          account: "Personal"
        },
        extra
      )
    end

    @today %{"time_min" => "2026-10-10T05:00:00Z", "time_max" => "2026-10-11T04:59:59Z"}

    test "a named day: Today, times in local time, all-day first" do
      result = %{
        events: [
          event("Tanya's birthday", "2026-10-10", %{all_day?: true, end: "2026-10-11"}),
          event("Soccer practice", "2026-10-10T17:30:00-05:00", %{
            location: "Westhaven Park, 100 Main St, Belleville, IL 62221"
          }),
          event("Dinner with the Hales", "2026-10-10T23:00:00Z", %{account: "Work"})
        ],
        errors: [],
        accounts_read: ["Personal", "Work"]
      }

      c = card("get_calendar_events", @today, result)

      assert c.type == "agenda"
      assert c.title == "Today"
      assert c.subtitle == "Sat, Oct 10"

      assert [
               %{time: "All day", title: "Tanya's birthday", account: "Personal"},
               %{
                 time: "5:30 PM",
                 title: "Soccer practice",
                 location: "Westhaven Park",
                 account: "Personal"
               },
               %{time: "6:00 PM", title: "Dinner with the Hales", account: "Work"}
             ] = c.events

      refute Map.has_key?(hd(c.events), :day), "a single day needs no day headers"
      refute Map.has_key?(c, :more)
    end

    test "an account still labelled by its email is shortened for the card" do
      # Labels default to the address on connect; a full address doesn't fit a card row.
      result = %{
        events: [
          event("Standup", "2026-10-10T14:00:00Z", %{account: "dave@acme-corp.com"}),
          event("Run", "2026-10-10T15:00:00Z", %{account: "davidclausen2051@gmail.com"}),
          event("Dinner", "2026-10-10T23:00:00Z", %{account: "Family"})
        ],
        errors: [],
        accounts_read: ["dave@acme-corp.com", "davidclausen2051@gmail.com", "Family"]
      }

      assert Enum.map(card("get_calendar_events", @today, result).events, & &1.account) ==
               ["acme-corp.com", "davidclausen2051", "Family"]
    end

    test "account labels only appear when the shown events span more than one account" do
      result = %{
        events: [event("Standup", "2026-10-10T14:00:00Z")],
        errors: [],
        accounts_read: ["Personal"]
      }

      c = card("get_calendar_events", @today, result)
      refute Map.has_key?(hd(c.events), :account)

      # three accounts read, but every event is on one of them: no per-row label
      same = %{
        events: [event("A", "2026-10-10T14:00:00Z"), event("B", "2026-10-10T16:00:00Z")],
        errors: [],
        accounts_read: ["Personal", "Work", "Family"]
      }

      refute Enum.any?(
               card("get_calendar_events", @today, same).events,
               &Map.has_key?(&1, :account)
             )
    end

    test "tomorrow, a later day, this week, next week and an arbitrary range" do
      one = %{events: [event("X", "2026-10-11T15:00:00Z")], errors: [], accounts_read: ["P"]}

      title = fn args -> card("get_calendar_events", args, one).title end

      assert title.(%{"time_min" => "2026-10-11T05:00:00Z", "time_max" => "2026-10-12T05:00:00Z"}) ==
               "Tomorrow"

      assert title.(%{"time_min" => "2026-10-14T05:00:00Z", "time_max" => "2026-10-15T04:59:59Z"}) ==
               "Wed, Oct 14"

      # Mon Oct 5 .. Sun Oct 11 contains today
      assert title.(%{"time_min" => "2026-10-05T05:00:00Z", "time_max" => "2026-10-12T04:59:59Z"}) ==
               "This week"

      assert title.(%{"time_min" => "2026-10-12T05:00:00Z", "time_max" => "2026-10-19T04:59:59Z"}) ==
               "Next week"

      assert title.(%{"time_min" => "2026-10-20T05:00:00Z", "time_max" => "2026-10-23T04:59:59Z"}) ==
               "Oct 20 – 22"

      assert title.(%{"time_min" => "2026-10-29T05:00:00Z", "time_max" => "2026-11-03T05:59:59Z"}) ==
               "Oct 29 – Nov 2"

      # no range given: the tool's own default (the next 24h)
      assert title.(%{}) == "Upcoming"
    end

    test "a multi-day range labels each event's day, and caps shorter (day headers cost rows)" do
      events =
        for d <- 10..15, h <- [14, 22] do
          event("Event #{d}-#{h}", "2026-10-#{d}T#{h}:00:00Z")
        end

      args = %{"time_min" => "2026-10-10T05:00:00Z", "time_max" => "2026-10-17T04:59:59Z"}
      c = card("get_calendar_events", args, %{events: events, errors: [], accounts_read: ["P"]})

      assert c.title == "This week"
      assert length(c.events) == 6
      assert c.more == "+6 more"
      assert Enum.map(c.events, & &1.day) |> Enum.uniq() == ["Today", "Tomorrow", "Mon, Oct 12"]
    end

    test "a partial failure still shows what was read, with a note" do
      result = %{
        events: [event("Standup", "2026-10-10T14:00:00Z")],
        errors: [%{account: "Work", reason: "needs_reconnect"}],
        accounts_read: ["Personal", "Work"]
      }

      assert card("get_calendar_events", @today, result).note == "Couldn't read Work"
    end

    test "an empty calendar or a no-account note is not a card" do
      assert card("get_calendar_events", @today, %{events: [], errors: [], accounts_read: ["P"]}) ==
               nil

      assert card("get_calendar_events", @today, %{
               events: [],
               errors: [],
               note: "no Google accounts connected"
             }) == nil
    end
  end

  describe "list" do
    test "read_list: unchecked first, with a scope and a tally" do
      result = %{
        list: "Groceries",
        household: true,
        items: [
          %{text: "milk", checked: false},
          %{text: "eggs", checked: true},
          %{text: "butter", checked: false}
        ]
      }

      c = card("read_list", %{"list" => "groceries"}, result)

      assert c.type == "list"
      assert c.title == "Groceries"
      assert c.scope == "Household"
      assert c.summary == "2 left · 1 done"

      assert c.items == [
               %{text: "milk", done: false},
               %{text: "butter", done: false},
               %{text: "eggs", done: true}
             ]
    end

    test "a personal list says so; a long one truncates with +N more" do
      items = for i <- 1..11, do: %{text: "item #{i}", checked: false}
      c = card("read_list", %{}, %{list: "To-do", household: false, items: items})

      assert c.scope == "Yours"
      assert length(c.items) == 7
      assert c.more == "+4 more"
      assert c.summary == "11 left"
    end

    test "all done reads as such" do
      c =
        card("read_list", %{}, %{
          list: "To-do",
          household: true,
          items: [%{text: "a", checked: true}]
        })

      assert c.summary == "All done"
    end

    test "an empty list, or a list tool without items, is not a card" do
      assert card("read_list", %{}, %{list: "To-do", items: [], note: "nothing on To-do yet"}) ==
               nil

      assert card("add_to_list", %{"item" => "milk"}, %{
               item: "milk",
               list: "Groceries",
               household: true,
               assigned: "the household"
             }) == nil
    end
  end

  describe "reminders" do
    test "list_reminders: relative day + local time, cadence and tags" do
      result = %{
        reminders: [
          %{
            body: "take out the trash",
            due_at: "2026-10-11T00:30:00Z",
            kind: "reminder",
            shared: true,
            recurrence: %{"freq" => "weekly", "interval" => 1, "byday" => ["sat"]}
          },
          %{body: "call mom", due_at: "2026-10-11T14:00:00Z", kind: "reminder", shared: false},
          %{
            body: "check whether Bob replied",
            due_at: "2026-10-14T15:00:00Z",
            kind: "followup",
            shared: false
          },
          %{
            body: "renew passport",
            due_at: "2026-11-20T16:00:00Z",
            kind: "reminder",
            shared: false
          }
        ]
      }

      c = card("list_reminders", %{}, result)

      assert c.type == "reminders"
      assert c.title == "Reminders"

      assert c.items == [
               %{
                 text: "Take out the trash",
                 when: "Today, 7:30 PM",
                 cadence: "every Sat",
                 tag: "Household"
               },
               %{text: "Call mom", when: "Tomorrow, 9:00 AM"},
               %{text: "Check whether Bob replied", when: "Wed, 10:00 AM", tag: "Follow-up"},
               %{text: "Renew passport", when: "Nov 20, 10:00 AM"}
             ]
    end

    test "create_reminder: the one just set, with its cadence" do
      result = %{
        body: "water the ferns",
        due_at: "2026-10-12T13:00:00Z",
        assigned_to: "you",
        household: false,
        recurrence: %{"freq" => "daily", "interval" => 3}
      }

      c = card("create_reminder", %{}, result)
      assert c.title == "Reminder set"

      assert c.items == [
               %{text: "Water the ferns", when: "Mon, 8:00 AM", cadence: "every 3 days"}
             ]
    end

    test "create_followup: titled as one, so the row needs no Follow-up tag" do
      result = %{body: "check whether Bob replied", due_at: "2026-10-12T15:00:00Z"}
      c = card("create_followup", %{}, result)

      assert c.title == "Follow-up set"
      assert c.items == [%{text: "Check whether Bob replied", when: "Mon, 10:00 AM"}]
    end

    test "create_reminder for someone else is tagged for them" do
      result = %{
        body: "pick up the kids",
        due_at: "2026-10-12T21:00:00Z",
        assigned_to: "Tanya",
        household: false
      }

      assert [%{tag: "For Tanya"}] = card("create_reminder", %{}, result).items
    end

    test "no reminders, or a no-session note, is not a card" do
      assert card("list_reminders", %{}, %{reminders: []}) == nil
      assert card("create_reminder", %{}, %{note: "no user session — reminder not saved"}) == nil
    end
  end

  describe "email" do
    defp msg(from, subject, date, account \\ "Personal") do
      %{
        handle: "#{account}:#{subject}",
        from: from,
        subject: subject,
        date: date,
        snippet: "…",
        account: account
      }
    end

    test "search_email: sender names, subjects and a short when" do
      result = %{
        messages: [
          msg(
            ~s("Alice Smith" <alice@example.com>),
            "Lunch Tuesday?",
            "Sat, 10 Oct 2026 13:05:00 -0500"
          ),
          msg(
            "billing@utility.example",
            "Your October statement",
            "Fri, 9 Oct 2026 08:00:00 +0000",
            "Work"
          ),
          msg("Bob <bob@example.com>", "", "Tue, 06 Oct 2026 10:00:00 -0700 (PDT)"),
          msg("Carol <carol@example.com>", "Old thread", "Thu, 24 Sep 2026 09:00:00 GMT"),
          msg("Dee <dee@example.com>", "No date", nil),
          msg("Eve <eve@example.com>", "Sixth", "Thu, 24 Sep 2026 09:00:00 GMT")
        ],
        errors: [],
        accounts_read: ["Personal", "Work"]
      }

      c = card("search_email", %{}, result)

      assert c.type == "email"
      assert c.title == "Unread"
      refute Map.has_key?(c, :subtitle)
      assert c.more == "+1 more"

      assert c.rows == [
               %{
                 from: "Alice Smith",
                 subject: "Lunch Tuesday?",
                 when: "1:05 PM",
                 account: "Personal"
               },
               %{
                 from: "billing@utility.example",
                 subject: "Your October statement",
                 when: "Yesterday",
                 account: "Work"
               },
               %{from: "Bob", subject: "(no subject)", when: "Tue", account: "Personal"},
               %{from: "Carol", subject: "Old thread", when: "Sep 24", account: "Personal"},
               %{from: "Dee", subject: "No date", account: "Personal"}
             ]
    end

    test "a query becomes the subtitle; one account drops the account labels" do
      result = %{
        messages: [msg("Alice <a@x.com>", "Invoice", "Sat, 10 Oct 2026 13:05:00 -0500")],
        errors: [],
        accounts_read: ["Personal"]
      }

      c = card("search_email", %{"query" => "subject:invoice"}, result)
      assert c.title == "Email"
      assert c.subtitle == "subject:invoice"
      refute Map.has_key?(hd(c.rows), :account)
    end

    test "no messages is not a card" do
      assert card("search_email", %{}, %{messages: [], errors: [], accounts_read: ["P"]}) == nil
    end
  end

  describe "robustness" do
    test "unknown tools and non-map results are not cards" do
      assert card("home_control", %{}, %{ok: true}) == nil
      assert card("get_weather", %{}, "sunny") == nil
      assert card("get_weather", nil, nil) == nil
    end

    test "a malformed result returns nil instead of raising" do
      assert card("get_weather", %{}, %{location: "X", current: %{temp_f: "hot"}}) == nil

      assert card("get_calendar_events", @today, %{events: [%{start: 12, summary: nil}]}) == nil
      assert card("list_reminders", %{}, %{reminders: [%{body: "x", due_at: "soon"}]}) == nil
      assert card("read_list", %{}, %{list: "X", items: [:not_a_map]}) == nil
    end
  end
end
