defmodule App.Cards do
  @moduledoc """
  Visual answers: a tool's raw result, shaped into a display-ready card for the client's
  thread ("What's the weather?" deserves a glanceable card, not only a paragraph).

  Pure, and the server owns every string — local times in the instance timezone, units inside
  the strings ("72°", "35%", "8 mph S") — so the client only lays out (the same rule the
  panels follow: render what the channel sent). Keys are atoms here and strings on the wire.

  v1 types: `weather` (get_weather), `agenda` (get_calendar_events), `list` (read_list),
  `reminders` (list_reminders / create_reminder / create_followup) and `email`
  (search_email). Everything else — an unknown tool, an error- or note-shaped result, an
  empty one — is `nil`. A malformed result never raises: a card is decoration and must never
  cost the turn, so it logs at debug and returns `nil`.
  """
  require Logger

  @agenda_cap_day 8
  @agenda_cap_range 6
  @list_cap 7
  @reminders_cap 6
  @email_cap 5
  # A chance of rain below this is noise on a card ("5%"), so it is omitted.
  @precip_floor 20

  @doc """
  The card for one tool result, or nil. `opts`: `:now` (UTC `DateTime`) and `:tz` (IANA zone)
  pin "today" for tests; they default to the clock and `App.Config.timezone/0`.
  """
  @spec from_tool(String.t(), map() | nil, term(), keyword()) :: map() | nil
  def from_tool(name, args, result, opts \\ []) do
    ctx = %{
      now: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0),
      tz: Keyword.get_lazy(opts, :tz, &App.Config.timezone/0)
    }

    build(name, args || %{}, result, ctx)
  rescue
    e ->
      Logger.debug("[cards] #{name} result is not card-shaped: #{Exception.message(e)}")
      nil
  end

  defp build("get_weather", _args, %{current: %{} = cur} = r, _ctx), do: weather(r, cur)

  defp build("get_calendar_events", args, %{events: [_ | _] = events} = r, ctx),
    do: agenda(args, events, r, ctx)

  defp build("read_list", _args, %{items: [_ | _] = items} = r, _ctx), do: list_card(r, items)

  defp build("add_to_list", _args, %{items: [_ | _] = items, added: [_ | _] = added} = r, _ctx),
    do: r |> list_card(items) |> Map.put(:summary, added_tally(added, items))

  defp build("list_reminders", _args, %{reminders: [_ | _] = rs}, ctx),
    do: reminders_card("Reminders", rs, ctx)

  defp build("create_reminder", _args, %{body: _, due_at: _} = r, ctx),
    do: reminders_card("Reminder set", [r], ctx)

  defp build("create_followup", _args, %{body: _, due_at: _} = r, ctx),
    do: reminders_card("Follow-up set", [r], ctx)

  defp build("search_email", args, %{messages: [_ | _] = msgs} = r, ctx),
    do: email_card(args, msgs, r, ctx)

  defp build(_name, _args, _result, _ctx), do: nil

  # ---- weather ----

  defp weather(r, cur) do
    daily = r[:daily] || []
    today = List.first(daily) || %{}
    sun = Map.new(daily, &{&1.date, {&1.sunrise, &1.sunset}})

    compact(%{
      type: "weather",
      location: r[:location],
      temp: deg!(cur.temp_f),
      condition: sentence(cur[:conditions]),
      icon: weather_icon(cur[:conditions], cur[:is_day] != false, cur[:wind_mph], cur[:gust_mph]),
      hi: deg(today[:high_f]),
      lo: deg(today[:low_f]),
      details: details(cur, today),
      hourly: r |> Map.get(:hourly, []) |> Enum.take(6) |> Enum.map(&hour(&1, sun)),
      daily: daily |> Enum.drop(1) |> Enum.take(5) |> Enum.map(&day/1)
    })
  end

  # The small labelled stats under the headline. Labelled HERE so the client renders copy it
  # was sent. Today's chance shows even at 0% — "no rain today" is an answer, unlike a 5% hour.
  defp details(cur, today) do
    precip_label =
      if String.contains?(today[:conditions] || "", "snow"), do: "Snow", else: "Rain"

    [
      {"Feels like", deg(cur[:feels_like_f])},
      {"Wind", wind(cur[:wind_mph], cur[:wind_dir])},
      {precip_label, pct(today[:precip_chance])}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
    |> Enum.map(fn {label, value} -> %{label: label, value: value} end)
  end

  defp hour(h, sun) do
    {date, clock} = split_local(h.time)

    day? =
      case Map.get(sun, date) do
        {rise, set} when is_binary(rise) and is_binary(set) -> h.time >= rise and h.time < set
        _ -> true
      end

    compact(%{
      label: hour_label(clock),
      temp: deg!(h.temp_f),
      condition: sentence(h[:conditions]),
      icon: weather_icon(h[:conditions], day?, h[:wind_mph], h[:gust_mph]),
      precip: precip(h[:precip_chance])
    })
  end

  defp day(d) do
    compact(%{
      label: d.date |> Date.from_iso8601!() |> Calendar.strftime("%a"),
      hi: deg!(d.high_f),
      lo: deg!(d.low_f),
      condition: sentence(d[:conditions]),
      icon: weather_icon(d[:conditions], true, d[:wind_mph_max], d[:gust_mph_max]),
      precip: precip(d[:precip_chance])
    })
  end

  @dry %{"clear" => "clear", "mostly clear" => "clear", "partly cloudy" => "partly"}

  @doc """
  The glyph key for a condition phrase (`App.Tools.Weather.code_phrase/1`'s vocabulary):
  clear | partly (each with a `_night` variant) | cloudy | rain | storm | snow | fog | wind.
  `wind` only replaces a dry sky — rain in a gale is still rain.
  """
  def weather_icon(phrase, day?, wind_mph, gust_mph) do
    phrase = phrase || ""

    base =
      cond do
        Map.has_key?(@dry, phrase) -> @dry[phrase]
        phrase == "overcast" -> "cloudy"
        phrase == "fog" -> "fog"
        String.contains?(phrase, "thunder") -> "storm"
        String.contains?(phrase, "snow") -> "snow"
        String.contains?(phrase, ["rain", "drizzle", "shower"]) -> "rain"
        true -> "cloudy"
      end

    windy? = (wind_mph || 0) >= 20 or (gust_mph || 0) >= 30

    cond do
      base in ["clear", "partly", "cloudy"] and windy? -> "wind"
      base in ["clear", "partly"] and not day? -> base <> "_night"
      true -> base
    end
  end

  defp deg(nil), do: nil
  defp deg(n), do: deg!(n)
  defp deg!(n) when is_number(n), do: "#{round(n)}°"

  defp precip(n) when is_number(n) and n >= @precip_floor, do: pct(n)
  defp precip(_), do: nil

  defp pct(n) when is_number(n), do: "#{round(n)}%"
  defp pct(_), do: nil

  defp wind(mph, dir) when is_number(mph),
    do: Enum.join(Enum.reject(["#{round(mph)} mph", dir], &is_nil/1), " ")

  defp wind(_, _), do: nil

  # Open-Meteo's times are the LOCATION's local wall clock ("2026-10-10T15:00"), already right
  # for wherever was asked about — never shift them into the instance timezone.
  defp split_local(iso) do
    [date, clock] = String.split(iso, "T", parts: 2)
    {date, clock}
  end

  defp hour_label(clock) do
    [h | _] = String.split(clock, ":")

    case String.to_integer(h) do
      0 -> "12AM"
      12 -> "12PM"
      n when n < 12 -> "#{n}AM"
      n -> "#{n - 12}PM"
    end
  end

  # ---- agenda ----

  defp agenda(args, events, r, ctx) do
    {title, subtitle, multi_day?} = agenda_title(args, events, ctx)
    # Label rows with their account only when the SHOWN events actually come from more than
    # one calendar: three connected accounts with every event on one of them is noise per row.
    multi_account? = events |> Enum.map(& &1[:account]) |> Enum.uniq() |> length() > 1
    cap = if multi_day?, do: @agenda_cap_range, else: @agenda_cap_day

    compact(%{
      type: "agenda",
      title: title,
      subtitle: subtitle,
      events:
        events |> Enum.take(cap) |> Enum.map(&event_row(&1, multi_day?, multi_account?, ctx)),
      more: more(length(events) - cap),
      note: agenda_note(r[:errors])
    })
  end

  defp event_row(e, multi_day?, multi_account?, ctx) do
    {date, time} =
      if e[:all_day?] == true do
        {Date.from_iso8601!(e.start), "All day"}
      else
        local = e.start |> parse_dt!() |> local(ctx)
        {DateTime.to_date(local), clock(local)}
      end

    compact(%{
      time: time,
      title: e.summary || "(no title)",
      location: short_location(e[:location]),
      account: if(multi_account?, do: account_label(e[:account])),
      day: if(multi_day?, do: day_name(date, ctx))
    })
  end

  defp agenda_title(args, events, ctx) do
    today = today(ctx)

    with {:ok, tmin} <- parse_dt(args["time_min"]),
         {:ok, tmax} <- parse_dt(args["time_max"]) do
      d0 = tmin |> local(ctx) |> DateTime.to_date()
      # time_max is usually an exclusive midnight or 23:59:59 — both end on the day before
      d1 = tmax |> DateTime.add(-1, :second) |> local(ctx) |> DateTime.to_date()
      span = Date.diff(d1, d0)

      cond do
        span <= 0 ->
          {day_name(d0, ctx), subtitle_for(d0, today), false}

        span in 5..7 and Date.compare(d0, today) != :gt and Date.compare(d1, today) != :lt ->
          {"This week", nil, true}

        span in 5..7 and Date.diff(d0, today) in 1..7 ->
          {"Next week", nil, true}

        true ->
          {range_label(d0, d1), nil, true}
      end
    else
      _ ->
        dates =
          events
          |> Enum.map(fn e ->
            if e[:all_day?] == true,
              do: Date.from_iso8601!(e.start),
              else: e.start |> parse_dt!() |> local(ctx) |> DateTime.to_date()
          end)
          |> Enum.uniq()

        {"Upcoming", nil, length(dates) > 1}
    end
  end

  # Today/Tomorrow get the date underneath; a named date already is one.
  defp subtitle_for(date, today) do
    if Date.diff(date, today) in [-1, 0, 1], do: Calendar.strftime(date, "%a, %b %-d")
  end

  defp range_label(d0, d1) do
    if d0.month == d1.month and d0.year == d1.year,
      do: "#{Calendar.strftime(d0, "%b %-d")} – #{d1.day}",
      else: "#{Calendar.strftime(d0, "%b %-d")} – #{Calendar.strftime(d1, "%b %-d")}"
  end

  # "Westhaven Park, 100 Main St, Belleville, IL" → "Westhaven Park": a glance, not an address.
  defp short_location(loc) when is_binary(loc) do
    case loc |> String.split([",", "\n"]) |> hd() |> String.trim() do
      "" -> nil
      short -> short
    end
  end

  defp short_location(_), do: nil

  defp agenda_note([_ | _] = errors),
    do: "Couldn't read " <> (errors |> Enum.map(& &1.account) |> Enum.join(", "))

  defp agenda_note(_), do: nil

  # ---- list ----

  defp list_card(r, items) do
    rows =
      Enum.map(items, fn %{text: text} = i ->
        %{text: to_string(text), done: i[:checked] == true}
      end)

    {done, open} = Enum.split_with(rows, & &1.done)
    ordered = open ++ done

    compact(%{
      type: "list",
      title: to_string(r.list),
      scope: if(r[:household] == false, do: "Yours", else: "Household"),
      summary: tally(length(open), length(done)),
      items: Enum.take(ordered, @list_cap),
      more: more(length(ordered) - @list_cap)
    })
  end

  defp added_tally(added, items) do
    open = Enum.count(items, &(&1[:checked] != true))
    "Added #{length(added)} · #{open} left"
  end

  defp tally(0, _done), do: "All done"
  defp tally(open, 0), do: "#{open} left"
  defp tally(open, done), do: "#{open} left · #{done} done"

  # ---- reminders ----

  defp reminders_card(title, rs, ctx) do
    compact(%{
      type: "reminders",
      title: title,
      items: rs |> Enum.take(@reminders_cap) |> Enum.map(&reminder_row(&1, ctx)),
      more: more(length(rs) - @reminders_cap)
    })
  end

  defp reminder_row(r, ctx) do
    due = parse_dt!(r.due_at)

    compact(%{
      text: capitalize(r.body),
      when: when_label(due, ctx),
      cadence: AppWeb.ReminderFormat.fmt_recurrence(r[:recurrence], due),
      tag: reminder_tag(r)
    })
  end

  defp reminder_tag(r) do
    cond do
      r[:kind] == "followup" -> "Follow-up"
      r[:shared] == true or r[:household] == true -> "Household"
      r[:assigned_to] not in [nil, "you", "the household"] -> "For #{r.assigned_to}"
      true -> nil
    end
  end

  # "Today, 7:30 PM" / "Tomorrow, 9:00 AM" / "Wed, 10:00 AM" / "Nov 20, 10:00 AM"
  defp when_label(dt, ctx) do
    local = local(dt, ctx)
    date = DateTime.to_date(local)

    day =
      case Date.diff(date, today(ctx)) do
        0 -> "Today"
        1 -> "Tomorrow"
        n when n in 2..6 -> Calendar.strftime(date, "%a")
        _ -> Calendar.strftime(date, "%b %-d")
      end

    "#{day}, #{clock(local)}"
  end

  # ---- email ----

  defp email_card(args, msgs, _r, ctx) do
    multi_account? = msgs |> Enum.map(& &1[:account]) |> Enum.uniq() |> length() > 1
    query = blank_to_nil(args["query"])

    compact(%{
      type: "email",
      title: if(query, do: "Email", else: "Unread"),
      subtitle: query,
      rows: msgs |> Enum.take(@email_cap) |> Enum.map(&email_row(&1, multi_account?, ctx)),
      more: more(length(msgs) - @email_cap)
    })
  end

  defp email_row(m, multi_account?, ctx) do
    compact(%{
      from: sender(m[:from]),
      subject: blank_to_nil(m[:subject]) || "(no subject)",
      when: m[:date] |> parse_rfc2822() |> received_label(ctx),
      account: if(multi_account?, do: account_label(m[:account]))
    })
  end

  # `"Alice Smith" <alice@example.com>` → Alice Smith; a bare address stays the address.
  defp sender(nil), do: "Unknown sender"

  defp sender(from) do
    case Regex.run(~r/^\s*"?([^"<]*?)"?\s*<([^>]+)>/, from) do
      [_, "", addr] -> addr
      [_, name, _addr] -> name
      nil -> String.trim(from)
    end
  end

  defp received_label(nil, _ctx), do: nil

  defp received_label(dt, ctx) do
    local = local(dt, ctx)
    date = DateTime.to_date(local)

    case Date.diff(today(ctx), date) do
      0 -> clock(local)
      1 -> "Yesterday"
      n when n in 2..6 -> Calendar.strftime(date, "%a")
      _ -> Calendar.strftime(date, "%b %-d")
    end
  end

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)
  @zones %{
    "UT" => 0,
    "UTC" => 0,
    "GMT" => 0,
    "Z" => 0,
    "EST" => -500,
    "EDT" => -400,
    "CST" => -600,
    "CDT" => -500,
    "MST" => -700,
    "MDT" => -600,
    "PST" => -800,
    "PDT" => -700
  }

  # An RFC 2822 Date header ("Tue, 06 Oct 2026 10:00:00 -0700 (PDT)") → UTC, or nil.
  @doc false
  def parse_rfc2822(date) when is_binary(date) do
    re =
      ~r/(\d{1,2})\s+([A-Za-z]{3})[a-z]*\s+(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4}|[A-Z]{1,3})?/

    with [_, d, mon, y, h, mi | rest] <- Regex.run(re, date),
         idx when is_integer(idx) <- Enum.find_index(@months, &(&1 == String.downcase(mon))),
         {:ok, naive} <-
           NaiveDateTime.new(
             String.to_integer(y),
             idx + 1,
             String.to_integer(d),
             String.to_integer(h),
             String.to_integer(mi),
             rest |> Enum.at(0) |> int_or_zero()
           ) do
      offset = rest |> Enum.at(1) |> zone_offset()
      hours = div(offset, 100)
      mins = rem(offset, 100)

      naive
      |> DateTime.from_naive!("Etc/UTC")
      |> DateTime.add(-(hours * 3600 + mins * 60), :second)
    else
      _ -> nil
    end
  end

  def parse_rfc2822(_), do: nil

  defp int_or_zero(s) when is_binary(s) and s != "", do: String.to_integer(s)
  defp int_or_zero(_), do: 0

  defp zone_offset("+" <> digits), do: String.to_integer(digits)
  defp zone_offset("-" <> digits), do: -String.to_integer(digits)
  defp zone_offset(name) when is_binary(name), do: Map.get(@zones, name, 0)
  defp zone_offset(_), do: 0

  # ---- shared helpers ----

  defp parse_dt(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> {:ok, dt}
      err -> err
    end
  end

  defp parse_dt(_), do: :error

  defp parse_dt!(iso) do
    {:ok, dt} = parse_dt(iso)
    dt
  end

  defp local(dt, ctx), do: DateTime.shift_zone!(dt, ctx.tz)
  defp today(ctx), do: ctx.now |> local(ctx) |> DateTime.to_date()
  defp clock(local), do: Calendar.strftime(local, "%-I:%M %p")

  defp day_name(date, ctx) do
    case Date.diff(date, today(ctx)) do
      0 -> "Today"
      1 -> "Tomorrow"
      _ -> Calendar.strftime(date, "%a, %b %-d")
    end
  end

  @consumer_mail ~w(gmail.com googlemail.com icloud.com me.com outlook.com hotmail.com live.com
                    yahoo.com proton.me protonmail.com)

  # A Google account's label defaults to its address, which doesn't fit a card row. Two
  # personal Gmails differ by the local part; a work account is best named by its domain.
  defp account_label(label) when is_binary(label) do
    case String.split(label, "@") do
      [local, domain] when local != "" and domain != "" ->
        if String.downcase(domain) in @consumer_mail, do: local, else: domain

      _ ->
        label
    end
  end

  defp account_label(_), do: nil

  defp more(n) when n > 0, do: "+#{n} more"
  defp more(_), do: nil

  defp sentence(nil), do: nil
  defp sentence(s), do: capitalize(s)

  defp capitalize(s) when is_binary(s) do
    {first, rest} = String.split_at(String.trim(s), 1)
    String.upcase(first) <> rest
  end

  defp blank_to_nil(s) when is_binary(s) do
    if String.trim(s) == "", do: nil, else: String.trim(s)
  end

  defp blank_to_nil(_), do: nil

  # nil fields are dropped rather than sent as null: the client renders what is present.
  defp compact(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
