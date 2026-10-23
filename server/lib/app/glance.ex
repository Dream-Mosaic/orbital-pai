defmodule App.Glance do
  @moduledoc """
  What the idle orb and the wall's Today board show besides the clock: the weather now and
  ahead, what is on the calendar today and tomorrow, and today's pending reminders.

  Built from the SAME tools the brain calls (`App.Tools.execute/3`), so it shares their caching,
  timeouts and multi-account fan-out, and shaped by `App.Cards` so the weather glyph key and
  "64°" formatting match the weather card exactly. One weather read feeds `weather` and
  `forecast`; one calendar read feeds `next_event` and `agenda`; reminders come from
  `App.Reminders.list_upcoming/2` (own + household). Each part is independent and optional: no
  calendar connected, a weather outage or a failed read drops that part (nil, or an empty
  list) and keeps the rest.

  Pushed by `AppWeb.VoiceChannel` as `"glance"` after join and on a slow refresh. `weather` and
  `next_event` are the original pair the orb face reads; the other three were added for the
  Today board and an older app ignores them. Wire shape (every string display-ready; the
  client lays out):

      %{weather: %{temp: "64°", condition: "Partly cloudy", icon: "partly_night"} | nil,
        next_event:
          %{title: "Dinner with Mom", time: "7:30 PM", day: "Today", at: "2026-10-11T00:30:00Z"}
          | nil,
        # up to 6, now through the end of tomorrow; an event in progress stays until it ends
        agenda: [
          %{title: "Mom's birthday", time: "All day", day: "Today", all_day: true, at: nil},
          %{title: "Dentist", time: "9:00 AM", day: "Tomorrow", all_day: false,
            at: "2026-10-11T14:00:00Z"}
        ],
        # the weather card's own rows: the next 6 hours, then the 3 days after today
        forecast:
          %{hourly: [%{label: "3PM", temp: "64°", condition: "Partly cloudy", icon: "partly",
                       precip: "30%"}],
            daily: [%{label: "Sun", hi: "68°", lo: "50°", condition: "Clear", icon: "clear"}]}
          | nil,
        # up to 5 unfired, due between now and the end of today, soonest first
        reminders: [%{text: "Take out the bins", time: "8:00 PM", household: true}]}

  `precip` appears on a forecast row only when the chance is worth showing (the card's rule).
  """
  require Logger

  @agenda_cap 6
  @hourly_cap 6
  @daily_cap 3
  @reminders_cap 5
  @timeout_ms 25_000

  @type t :: %{
          weather: map() | nil,
          next_event: map() | nil,
          agenda: [map()],
          forecast: map() | nil,
          reminders: [map()]
        }

  @doc "The glance for `user_id`. Options: `:config`, `:now` (UTC), `:tz` — for tests."
  @spec build(integer(), keyword()) :: t()
  def build(user_id, opts \\ []) do
    config = Keyword.get_lazy(opts, :config, &App.Config.default/0)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    tz = Keyword.get_lazy(opts, :tz, &App.Config.timezone/0)
    ctx = %{session_id: to_string(user_id), user_id: user_id, config: config}

    [card, events, reminders] =
      parallel([
        {:weather, nil, fn -> weather_card(ctx, now, tz) end},
        {:calendar, nil, fn -> calendar_events(ctx, now, tz) end},
        {:reminders, [], fn -> reminders(user_id, now, tz) end}
      ])

    %{
      weather: safe(:weather, nil, fn -> weather(card) end),
      next_event: safe(:next_event, nil, fn -> next_event(events, now, tz) end),
      agenda: safe(:agenda, [], fn -> agenda(events, now, tz) end),
      forecast: safe(:forecast, nil, fn -> forecast(card) end),
      reminders: reminders
    }
  end

  # Each `{name, default, fun}` runs in its own task; a crash or a timeout yields the default,
  # so one bad part never costs the others.
  defp parallel(parts) do
    tasks =
      Enum.map(parts, fn {name, default, fun} ->
        Task.async(fn -> safe(name, default, fun) end)
      end)

    tasks
    |> Task.yield_many(@timeout_ms)
    |> Enum.zip(parts)
    |> Enum.map(fn
      {{_task, {:ok, value}}, _part} ->
        value

      {{task, nil}, {name, default, _fun}} ->
        Task.shutdown(task, :brutal_kill)
        Logger.warning("[glance] #{name} timed out")
        default

      {{_task, {:exit, _reason}}, {name, default, _fun}} ->
        Logger.warning("[glance] #{name} exited")
        default
    end)
  end

  defp safe(name, default, fun) do
    fun.()
  rescue
    e ->
      # the message can quote the data it choked on (a title, a reminder), so it goes through
      # LogText like anything else a person wrote
      Logger.warning(
        "[glance] #{name} failed: #{inspect(e.__struct__)} #{App.LogText.said(Exception.message(e))}"
      )

      default
  catch
    kind, _reason ->
      Logger.warning("[glance] #{name} failed: #{kind}")
      default
  end

  # ---- weather + forecast (one read) ----

  defp weather_card(ctx, now, tz) do
    with {:ok, result} <- App.Tools.execute("get_weather", %{}, ctx),
         %{temp: _} = card <- App.Cards.from_tool("get_weather", %{}, result, now: now, tz: tz) do
      card
    else
      other ->
        Logger.debug("[glance] no weather: #{App.LogText.said(other)}")
        nil
    end
  end

  defp weather(%{temp: temp} = card),
    do: %{temp: temp, condition: card[:condition] || "", icon: card[:icon] || ""}

  defp weather(_), do: nil

  # The card already starts its hourly rows at the current hour and drops today from `daily`
  # (today's hi/lo ride the headline).
  defp forecast(%{temp: _} = card) do
    %{
      hourly: card |> Map.get(:hourly, []) |> Enum.take(@hourly_cap),
      daily: card |> Map.get(:daily, []) |> Enum.take(@daily_cap)
    }
  end

  defp forecast(_), do: nil

  # ---- calendar: next_event + agenda (one read) ----

  defp calendar_events(ctx, now, tz) do
    args = %{
      "time_min" => DateTime.to_iso8601(now),
      "time_max" => DateTime.to_iso8601(window_end(now, tz))
    }

    case App.Tools.execute("get_calendar_events", args, ctx) do
      {:ok, %{events: events}} when is_list(events) ->
        events

      other ->
        Logger.debug("[glance] no calendar: #{App.LogText.said(other)}")
        nil
    end
  end

  # The first TIMED event still ahead of us, today or tomorrow. All-day events are skipped: "All
  # day · Mom's birthday" is not what "next" means on a clock face, and they would shadow the
  # dentist at 9.
  defp next_event(events, now, tz) when is_list(events) do
    today = local_date(now, tz)

    with %{} = event <- Enum.find(events, &upcoming_timed?(&1, now)),
         {:ok, start, _} <- DateTime.from_iso8601(event.start) do
      local = DateTime.shift_zone!(start, tz)

      %{
        title: event[:summary] || "(no title)",
        time: clock(local),
        day: day_label(DateTime.to_date(local), today),
        # the instant, so the face can drop an event the moment it starts instead of showing
        # it as "next" until the following refresh
        at: utc_iso(start)
      }
    else
      _ -> nil
    end
  end

  defp next_event(_, _now, _tz), do: nil

  defp upcoming_timed?(%{all_day?: true}, _now), do: false

  defp upcoming_timed?(%{start: start}, now) when is_binary(start) do
    case DateTime.from_iso8601(start) do
      {:ok, dt, _} -> DateTime.compare(dt, now) == :gt
      _ -> false
    end
  end

  defp upcoming_timed?(_, _), do: false

  # Everything from now through the end of tomorrow, timed and all-day. An event in progress
  # stays until its end ("Poke the Brain, 1:00 PM" while it runs); with no end, until its start.
  # Each day's all-day events lead it, then the timed ones by start.
  defp agenda(events, now, tz) when is_list(events) do
    today = local_date(now, tz)

    span = %{
      now: now,
      tz: tz,
      today: today,
      tomorrow: Date.add(today, 1),
      end: window_end(now, tz)
    }

    events
    |> Enum.flat_map(&agenda_item(&1, span))
    |> Enum.sort_by(fn {key, _item} -> key end)
    |> Enum.take(@agenda_cap)
    |> Enum.map(fn {_key, item} -> item end)
  end

  defp agenda(_, _now, _tz), do: []

  defp agenda_item(%{all_day?: true, start: start} = event, span) when is_binary(start) do
    with {:ok, first} <- Date.from_iso8601(start),
         true <- Date.compare(first, span.tomorrow) != :gt,
         true <- all_day_running?(event, first, span.today) do
      day = Enum.max([first, span.today], Date)

      [
        {{Date.to_gregorian_days(day), 0, Date.to_gregorian_days(first)},
         %{
           title: title(event),
           time: "All day",
           day: day_label(day, span.today),
           all_day: true,
           at: nil
         }}
      ]
    else
      _ -> []
    end
  end

  defp agenda_item(%{start: start} = event, span) when is_binary(start) do
    with {:ok, at, _} <- DateTime.from_iso8601(start),
         :lt <- DateTime.compare(at, span.end),
         true <- timed_running?(event, at, span.now) do
      local = DateTime.shift_zone!(at, span.tz)
      date = DateTime.to_date(local)

      [
        {{Date.to_gregorian_days(date), 1, DateTime.to_unix(at)},
         %{
           title: title(event),
           time: clock(local),
           day: day_label(date, span.today),
           all_day: false,
           at: utc_iso(at)
         }}
      ]
    else
      _ -> []
    end
  end

  defp agenda_item(_event, _span), do: []

  # An all-day event's end date is EXCLUSIVE (Google's convention), so it is over once that
  # date has arrived. Without an end, it is a single day.
  defp all_day_running?(event, first, today) do
    case event[:end] do
      e when is_binary(e) and byte_size(e) > 0 ->
        case Date.from_iso8601(e) do
          {:ok, last_exclusive} -> Date.compare(last_exclusive, today) == :gt
          _ -> Date.compare(first, today) != :lt
        end

      _ ->
        Date.compare(first, today) != :lt
    end
  end

  defp timed_running?(event, start, now) do
    with e when is_binary(e) <- event[:end],
         {:ok, finish, _} <- DateTime.from_iso8601(e) do
      DateTime.compare(finish, now) == :gt
    else
      _ -> DateTime.compare(start, now) == :gt
    end
  end

  defp title(event), do: event[:summary] || "(no title)"

  # ---- reminders ----

  # Today's pending (unfired) reminders, own and household, due between now and local midnight.
  defp reminders(user_id, now, tz) when is_integer(user_id) do
    tonight = local_midnight(Date.add(local_date(now, tz), 1), tz)

    user_id
    |> App.Reminders.list_upcoming(now)
    |> Enum.filter(&(DateTime.compare(&1.due_at, tonight) == :lt))
    |> Enum.take(@reminders_cap)
    |> Enum.map(fn r ->
      %{
        text: capitalize(r.body),
        time: r.due_at |> DateTime.shift_zone!(tz) |> clock(),
        household: r.household == true
      }
    end)
  end

  defp reminders(_user_id, _now, _tz), do: []

  # ---- shared ----

  # The calendar window: now through the end of tomorrow, local.
  defp window_end(now, tz), do: local_midnight(Date.add(local_date(now, tz), 2), tz)

  defp local_date(now, tz), do: now |> DateTime.shift_zone!(tz) |> DateTime.to_date()

  defp day_label(date, today) do
    case Date.diff(date, today) do
      0 -> "Today"
      1 -> "Tomorrow"
      _ -> Calendar.strftime(date, "%A")
    end
  end

  defp clock(dt) do
    hour = rem(dt.hour + 11, 12) + 1
    minute = dt.minute |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{hour}:#{minute} #{if dt.hour < 12, do: "AM", else: "PM"}"
  end

  defp utc_iso(dt), do: dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()

  defp capitalize(s) when is_binary(s) do
    {first, rest} = String.split_at(String.trim(s), 1)
    String.upcase(first) <> rest
  end

  defp capitalize(_), do: ""

  defp local_midnight(date, tz) do
    case DateTime.new(date, ~T[00:00:00], tz) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:ambiguous, first, _} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _, after_gap} -> DateTime.shift_zone!(after_gap, "Etc/UTC")
    end
  end
end
