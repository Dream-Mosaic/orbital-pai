defmodule App.Glance do
  @moduledoc """
  What the idle orb shows besides the clock: the weather now and the next thing on the calendar.

  Built from the SAME tools the brain calls (`App.Tools.execute/3`), so it shares their caching,
  timeouts and multi-account fan-out, and shaped by `App.Cards` so the weather glyph key and
  "64°" formatting match the weather card exactly. Each half is independent and optional: no
  calendar connected, or a weather outage, drops that half and keeps the other.

  Pushed by `AppWeb.VoiceChannel` as `"glance"` after join and on a slow refresh. Wire shape
  (every string display-ready; the client lays out):

      %{weather: %{temp: "64°", condition: "Partly cloudy", icon: "partly-night"} | nil,
        next_event: %{title: "Dinner with Mom", time: "7:30 PM", day: "Today"} | nil}
  """
  require Logger

  @doc "The glance for `user_id`. Options: `:config`, `:now` (UTC), `:tz` — for tests."
  @spec build(integer(), keyword()) :: %{weather: map() | nil, next_event: map() | nil}
  def build(user_id, opts \\ []) do
    config = Keyword.get_lazy(opts, :config, &App.Config.default/0)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    tz = Keyword.get_lazy(opts, :tz, &App.Config.timezone/0)
    ctx = %{session_id: to_string(user_id), user_id: user_id, config: config}

    [weather, next_event] =
      [fn -> weather(ctx, now, tz) end, fn -> next_event(ctx, now, tz) end]
      |> Enum.map(&Task.async/1)
      |> Task.await_many(25_000)

    %{weather: weather, next_event: next_event}
  end

  defp weather(ctx, now, tz) do
    with {:ok, result} <- App.Tools.execute("get_weather", %{}, ctx),
         %{temp: temp} = card <- App.Cards.from_tool("get_weather", %{}, result, now: now, tz: tz) do
      %{temp: temp, condition: card[:condition] || "", icon: card[:icon] || ""}
    else
      other ->
        Logger.debug("[glance] no weather: #{inspect(other)}")
        nil
    end
  end

  # The first TIMED event still ahead of us, today or tomorrow. All-day events are skipped: "All
  # day · Mom's birthday" is not what "next" means on a clock face, and they would shadow the
  # dentist at 9.
  defp next_event(ctx, now, tz) do
    today = now |> DateTime.shift_zone!(tz) |> DateTime.to_date()
    window_end = local_midnight(Date.add(today, 2), tz)

    args = %{
      "time_min" => DateTime.to_iso8601(now),
      "time_max" => DateTime.to_iso8601(window_end)
    }

    with {:ok, %{events: events}} when is_list(events) <-
           App.Tools.execute("get_calendar_events", args, ctx),
         %{} = event <- Enum.find(events, &upcoming_timed?(&1, now)),
         {:ok, start, _} <- DateTime.from_iso8601(event.start) do
      local = DateTime.shift_zone!(start, tz)

      %{
        title: event[:summary] || "(no title)",
        time: clock(local),
        day: day_label(DateTime.to_date(local), today),
        # the instant, so the face can drop an event the moment it starts instead of showing
        # it as "next" until the following refresh
        at: start |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
      }
    else
      other ->
        Logger.debug("[glance] no next event: #{inspect(other)}")
        nil
    end
  end

  defp upcoming_timed?(%{all_day?: true}, _now), do: false

  defp upcoming_timed?(%{start: start}, now) when is_binary(start) do
    case DateTime.from_iso8601(start) do
      {:ok, dt, _} -> DateTime.compare(dt, now) == :gt
      _ -> false
    end
  end

  defp upcoming_timed?(_, _), do: false

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

  defp local_midnight(date, tz) do
    case DateTime.new(date, ~T[00:00:00], tz) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:ambiguous, first, _} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _, after_gap} -> DateTime.shift_zone!(after_gap, "Etc/UTC")
    end
  end
end
