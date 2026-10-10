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

  describe "tracker" do
    alias App.Trackers.Entry
    @tz "America/Chicago"

    defp entry(at, value, tags \\ [], note \\ nil),
      do: %Entry{recorded_at: at, value: value, tags: tags, note: note}

    # Newest first, as App.Trackers.entries/4 returns them.
    defp headaches do
      [
        entry(~U[2026-10-09 20:45:00Z], 7.0, ["skipped lunch"], "behind the eyes"),
        entry(~U[2026-10-07 14:10:00Z], 5.0, ["poor sleep"]),
        entry(~U[2026-10-05 23:00:00Z], 6.0, ["skipped lunch", "coffee"]),
        entry(~U[2026-10-05 13:00:00Z], 4.0),
        entry(~U[2026-09-28 22:00:00Z], 6.0, ["poor sleep"]),
        entry(~U[2026-09-21 18:30:00Z], 5.0, ["screen time"]),
        entry(~U[2026-09-12 16:00:00Z], 4.0)
      ]
    end

    # get_tracker_entries' result, assembled from the tool's own pure pieces (stats + entry
    # view) exactly as its range_result does.
    defp range(label, entries, since, until, unit \\ "pain 1-10") do
      %{
        tracker: label,
        unit: unit,
        timezone: @tz,
        since: since,
        until: until,
        total: length(entries),
        returned: length(entries),
        truncated: false,
        stats: App.Trackers.stats(entries, @tz),
        entries: Enum.map(entries, &App.Tools.Trackers.entry_view(&1, @tz))
      }
    end

    defp headache_card(since \\ "2026-09-10", until \\ "2026-10-10"),
      do: card("get_tracker_entries", %{}, range("headache", headaches(), since, until))

    test "the header and headline stats, display-ready" do
      c = headache_card()

      assert c.type == "tracker"
      assert c.title == "Headache"
      assert c.range == "Last 30 days"

      assert c.stats == [
               %{label: "Entries", value: "7"},
               %{label: "Avg", value: "5.3"},
               %{label: "Range", value: "4–7"}
             ]

      assert c.top_tags == ["poor sleep ×2", "skipped lunch ×2", "coffee"]
    end

    test "the series is the last 30 local days: max per day, gaps empty, the peak marked" do
      c = headache_card()

      assert length(c.series) == 30
      assert hd(c.series) == %{label: "Sep 11", count: 0}
      assert List.last(c.series) == %{label: "Oct 10", count: 0}
      assert Enum.at(c.series, 1) == %{label: "Sep 12", value: 4, count: 1}
      # two entries on Mon Oct 5 (4 and 6): the bar is the worse of them
      assert %{label: "Oct 5", value: 6, count: 2} = Enum.find(c.series, &(&1.label == "Oct 5"))

      assert [%{label: "Oct 9", value: 7, peak: "7"}] = Enum.filter(c.series, & &1[:peak])
    end

    test "recent entries say when, the value, and a note (or the tags in its place)" do
      assert headache_card().recent == [
               %{when: "Yesterday, 3:45 PM", value: "7", note: "behind the eyes"},
               %{when: "Wed, 9:10 AM", value: "5", note: "poor sleep"},
               %{when: "Mon, 6:00 PM", value: "6", note: "skipped lunch, coffee"}
             ]
    end

    test "a range that isn't the default reads as dates, and the series stays inside it" do
      c = headache_card("2026-10-01", "2026-10-10")
      assert c.range == "Oct 1 – 10"
      assert length(c.series) == 10
      assert hd(c.series).label == "Oct 1"

      september =
        card(
          "get_tracker_entries",
          %{},
          range("headache", Enum.drop(headaches(), 4), "2026-09-01", "2026-09-30")
        )

      assert september.range == "Sep 1 – 30"
      assert List.last(september.series).label == "Sep 30"
      assert september.stats |> hd() == %{label: "Entries", value: "3"}
    end

    test "a short unit rides on the values; a ties peak is the latest; one value is no range" do
      weights = [
        entry(~U[2026-10-10 13:00:00Z], 182.4),
        entry(~U[2026-10-09 13:00:00Z], 183.0),
        entry(~U[2026-10-08 13:00:00Z], 183.0)
      ]

      c =
        card(
          "get_tracker_entries",
          %{},
          range("weight", weights, "2026-09-10", "2026-10-10", "lb")
        )

      assert c.stats == [
               %{label: "Entries", value: "3"},
               %{label: "Avg", value: "182.8 lb"},
               %{label: "Range", value: "182.4–183 lb"}
             ]

      assert [%{label: "Oct 9", peak: "183"}] = Enum.filter(c.series, & &1[:peak])

      single =
        card(
          "get_tracker_entries",
          %{},
          range("weight", [hd(weights)], "2026-10-01", "2026-10-10")
        )

      assert %{label: "Range", value: "182.4"} in single.stats
    end

    test "a habit with no values counts days and streaks instead" do
      days =
        for d <- [3, 4, 5, 6, 8, 9],
            do: entry(DateTime.new!(Date.new!(2026, 10, d), ~T[17:00:00]), nil)

      c =
        card(
          "get_tracker_entries",
          %{},
          range("no soda", Enum.reverse(days), "2026-09-10", "2026-10-10", nil)
        )

      assert c.title == "No soda"

      assert c.stats == [
               %{label: "Entries", value: "6"},
               %{label: "Best streak", value: "4 days"}
             ]

      assert %{label: "Oct 4", count: 1} = Enum.find(c.series, &(&1.label == "Oct 4"))
      refute Enum.any?(c.series, & &1[:peak])
      assert hd(c.recent) == %{when: "Yesterday, 12:00 PM"}
      refute Map.has_key?(c, :top_tags)
    end

    test "an empty range is still a card (an answer: none); a missing tracker is not" do
      c = card("get_tracker_entries", %{}, range("headache", [], "2026-09-10", "2026-10-10"))
      assert c.stats == [%{label: "Entries", value: "0"}]
      assert Enum.all?(c.series, &(&1.count == 0))
      refute Map.has_key?(c, :recent)

      assert card("get_tracker_entries", %{}, %{
               note: "no tracker called \"migraines\"",
               trackers: ["headache"]
             }) == nil
    end

    test "log_tracker_entry: what was saved, so a mishearing shows" do
      [latest | _] = headaches()

      result = %{
        logged: true,
        tracker: "headache",
        created: false,
        unit: "pain 1-10",
        entry: App.Tools.Trackers.entry_view(latest, @tz),
        total_entries: 12
      }

      assert card("log_tracker_entry", %{}, result) == %{
               type: "tracker_logged",
               label: "Logged",
               title: "Headache",
               value: "7",
               note: "behind the eyes",
               tags: ["skipped lunch"],
               when: "Yesterday, 3:45 PM",
               summary: "12th entry"
             }

      first = %{result | created: true, total_entries: 1, entry: %{result.entry | value: nil}}
      c = card("log_tracker_entry", %{}, first)
      assert c.label == "New tracker"
      assert c.summary == "1st entry"
      refute Map.has_key?(c, :value)

      for {n, ord} <- [
            {2, "2nd"},
            {3, "3rd"},
            {11, "11th"},
            {12, "12th"},
            {13, "13th"},
            {22, "22nd"},
            {101, "101st"},
            {111, "111th"}
          ] do
        assert card("log_tracker_entry", %{}, %{result | total_entries: n}).summary ==
                 "#{ord} entry"
      end
    end

    test "other tracker results are not cards" do
      assert card("log_tracker_entry", %{}, %{note: "no user session — trackers unavailable"}) ==
               nil

      assert card("list_trackers", %{}, %{trackers: []}) == nil
      assert card("undo_tracker_entry", %{}, %{tracker: "headache", remaining: 3}) == nil
    end
  end

  describe "recipe" do
    defp lasagna(extra \\ %{}) do
      App.Tools.Recipes.recipe_view(
        struct(
          App.Recipes.Recipe,
          Map.merge(
            %{
              title: "Grandma's Lasagna",
              household: true,
              servings: "8",
              source: "Grandma",
              notes: "Freezes well. Use fresh basil if you have it.",
              ingredients: [
                "1 lb ground beef",
                "12 lasagna noodles",
                "2 cups ricotta cheese",
                "1 (24 oz) jar marinara",
                "½ tsp salt",
                "1 1/2 cups shredded mozzarella",
                "2 large eggs",
                "3 cloves garlic, minced",
                "1 cup of grated parmesan",
                "Fresh basil"
              ],
              steps: [
                "Preheat the oven to 375°F.",
                "Brown the beef with the garlic, about 8 minutes.",
                "Stir the eggs into the ricotta.",
                "Layer noodles, sauce, ricotta and mozzarella; repeat three times.",
                "Bake 25 to 30 minutes, then rest 10 min."
              ]
            },
            extra
          )
        )
      )
    end

    test "get_recipe: the overview, quantities split from the ingredient" do
      c = card("get_recipe", %{"name" => "lasagna"}, lasagna())

      assert c.type == "recipe"
      # a lookup has no status; only a write says what it did
      refute Map.has_key?(c, :status)
      assert c.title == "Grandma's Lasagna"
      # the shared book is the default, so only a private recipe is labelled
      refute Map.has_key?(c, :scope)
      assert c.meta == "Serves 8 · from Grandma"
      assert c.notes == "Freezes well. Use fresh basil if you have it."
      assert c.ingredients_label == "10 ingredients"
      assert c.steps_label == "5 steps"

      assert c.ingredients == [
               %{qty: "1 lb", item: "ground beef"},
               %{qty: "12", item: "lasagna noodles"},
               %{qty: "2 cups", item: "ricotta cheese"},
               %{qty: "1 (24 oz) jar", item: "marinara"},
               %{qty: "½ tsp", item: "salt"},
               %{qty: "1 1/2 cups", item: "shredded mozzarella"},
               %{qty: "2", item: "large eggs"},
               %{qty: "3 cloves", item: "garlic, minced"},
               %{qty: "1 cup", item: "grated parmesan"},
               %{item: "Fresh basil"}
             ]

      assert hd(c.steps) == %{number: "1", text: "Preheat the oven to 375°F."}
      assert List.last(c.steps).number == "5"
      refute Map.has_key?(c, :more_ingredients)
      refute Map.has_key?(c, :more_steps)
    end

    test "split_ingredient: amounts, ranges, unicode fractions; no amount is all item" do
      assert Cards.split_ingredient("8oz cream cheese") == %{qty: "8oz", item: "cream cheese"}

      assert Cards.split_ingredient("2-3 Tbsp. olive oil") == %{
               qty: "2-3 Tbsp.",
               item: "olive oil"
             }

      assert Cards.split_ingredient("1 ½ cups milk") == %{qty: "1 ½ cups", item: "milk"}
      assert Cards.split_ingredient("2 c. flour") == %{qty: "2 c.", item: "flour"}
      assert Cards.split_ingredient("4 garlic cloves") == %{qty: "4", item: "garlic cloves"}

      assert Cards.split_ingredient("1 large onion, diced") == %{
               qty: "1",
               item: "large onion, diced"
             }

      # a unit must be a whole word: "2 large" is not 2 litres of "arge"
      assert Cards.split_ingredient("2 lemons") == %{qty: "2", item: "lemons"}

      assert Cards.split_ingredient("Salt and pepper to taste") == %{
               item: "Salt and pepper to taste"
             }

      # an amount with nothing after it isn't split into an empty item
      assert Cards.split_ingredient("3 cups") == %{item: "3 cups"}
    end

    test "a long recipe caps both lists with +N more" do
      c =
        card(
          "get_recipe",
          %{},
          lasagna(%{
            ingredients: for(i <- 1..15, do: "#{i} cups thing #{i}"),
            steps: for(i <- 1..11, do: "Do thing #{i}.")
          })
        )

      assert length(c.ingredients) == 12
      assert c.more_ingredients == "+3 more"
      assert length(c.steps) == 8
      assert c.more_steps == "+3 more"
      assert c.ingredients_label == "15 ingredients"
    end

    test "meta: servings phrased sensibly, a URL source shown as its site, a personal scope" do
      meta = fn extra -> card("get_recipe", %{}, lasagna(extra)) end

      assert meta.(%{servings: "6 to 8"}).meta == "Serves 6 to 8 · from Grandma"
      assert meta.(%{servings: "24 cookies"}).meta == "24 cookies · from Grandma"

      assert meta.(%{servings: nil, source: "https://www.seriouseats.com/the-best-lasagna"}).meta ==
               "from seriouseats.com"

      c = meta.(%{servings: nil, source: nil, notes: nil, household: false})
      refute Map.has_key?(c, :meta)
      refute Map.has_key?(c, :notes)
      assert c.scope == "Yours"
    end

    test "save_recipe and edit_recipe show the recipe they wrote" do
      saved = %{
        saved: true,
        replaced: false,
        title: "Grandma's Lasagna",
        personal: false,
        ingredient_count: 10,
        step_count: 5,
        recipe: lasagna()
      }

      assert %{type: "recipe", status: "Saved"} = card("save_recipe", %{}, saved)

      assert %{status: "Replaced"} = card("save_recipe", %{}, %{saved | replaced: true})

      edited = %{edited: true, added: ["Fresh basil"], removed: [], recipe: lasagna()}
      assert %{type: "recipe", status: "Updated"} = card("edit_recipe", %{}, edited)

      # not saved (it already exists — the brain asks first) is no card
      assert card("save_recipe", %{}, %{saved: false, exists: true, title: "X", note: "…"}) ==
               nil

      assert card("get_recipe", %{}, %{note: "no recipe called \"flan\"", recipes: []}) == nil
    end
  end

  describe "cook_step" do
    defp cook(step), do: lasagna() |> Map.put(:current_step, step)

    test "get_recipe with a current step is that one step, large, with its timers" do
      c = card("get_recipe", %{"name" => "lasagna", "step" => 4}, cook(4))

      assert c == %{
               type: "cook_step",
               title: "Grandma's Lasagna",
               progress: "Step 4 of 5",
               step: 4,
               step_count: 5,
               text: "Layer noodles, sauce, ricotta and mozzarella; repeat three times.",
               next_label: "Next",
               # the opening words, minus a dangling comma, then an ellipsis
               next: "Bake 25 to 30 minutes…"
             }

      assert card("get_recipe", %{}, cook(2)).timers == ["8 minutes"]
    end

    test "the last step has no next, and says so" do
      c = card("get_recipe", %{}, cook(5))

      assert c.progress == "Step 5 of 5"
      assert c.timers == ["25 to 30 minutes", "10 min"]
      assert c.next_label == "Last step"
      refute Map.has_key?(c, :next)
    end

    test "a short next step is shown whole; a longer one by its opening words" do
      short = lasagna(%{steps: ["Boil the water.", "Add the pasta and salt.", "Drain."]})

      assert card("get_recipe", %{}, Map.put(short, :current_step, 1)).next ==
               "Add the pasta and salt."

      assert card("get_recipe", %{}, cook(2)).next == "Stir the eggs into the…"
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

      assert card("get_tracker_entries", %{}, %{tracker: "x", stats: %{count: 2}, entries: :no}) ==
               nil

      assert card("get_recipe", %{}, %{title: "X", ingredients: "flour", steps: nil}) == nil
      assert card("get_recipe", %{}, %{title: "X", steps: [], current_step: 1}) == nil
    end
  end
end
