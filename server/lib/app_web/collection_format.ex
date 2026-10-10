defmodule AppWeb.CollectionFormat do
  @moduledoc """
  The wire shapes, and every display string in them, for the Books panel's three collection
  books: the recipe book, the user's trackers and their routines (`App.Books.collections/0`).

  Rendered server-side for the same reason `AppWeb.BookFormat` exists: the native client lays
  these out and never formats a date, a number or a sentence of its own, so there is one copy
  of the copy. That includes each book's empty state and every delete confirmation, which are
  bound to the row they belong to.

  Pure: every function is handed `now` and the timezone and never reads the clock or the
  database. `AppWeb.Panels.BooksChannel` does the reads.
  """

  alias App.Recipes.Recipe
  alias App.Routines
  alias App.Routines.Routine
  alias App.Trackers

  # The chart's window, and the stats and top tags that sit under it.
  @window_days 30
  @recent_cap 20
  @tags_cap 5

  # ---------------------------------------------------------------------------------------------
  # Recipes

  @doc "The recipe book's body: its rows (in the caller's order) and its empty state."
  def recipes(recipes) do
    %{
      items: Enum.map(recipes, &recipe/1),
      empty: "No recipes yet.",
      hint: "Try: “Henry, save my lasagna recipe…”"
    }
  end

  @doc """
  One recipe: the list row (`title`, `tag`, `meta`) and the detail it opens onto
  (`detail_meta`, `ingredients`, `steps`, `notes`), plus the confirmation its Delete shows.
  `shared` is what the delete's explicit scope is derived from server-side, never a client
  choice.
  """
  def recipe(%Recipe{} = r) do
    %{
      id: r.id,
      title: r.title,
      shared: r.household,
      tag: if(r.household, do: "shared", else: "yours"),
      meta:
        "#{count(length(r.ingredients), "ingredient", "ingredients")} · " <>
          count(length(r.steps), "step", "steps"),
      detail_meta: join([servings(r.servings), source(r.source)]),
      ingredients: r.ingredients,
      steps: r.steps,
      notes: r.notes,
      delete_confirm: recipe_confirm(r)
    }
  end

  defp recipe_confirm(%Recipe{household: true, title: title}),
    do:
      "Delete “#{title}” from the shared recipe book? It goes for everyone, and can't be undone."

  defp recipe_confirm(%Recipe{title: title}),
    do: "Delete your recipe “#{title}”? This can't be undone."

  # "6" → "Serves 6"; "makes 24 cookies" → "Makes 24 cookies"; "6 people" → "Serves 6 people".
  defp servings(nil), do: nil

  defp servings(s) do
    if s =~ ~r/^(serves|makes|feeds|yields)\b/iu,
      do: upcase_first(s),
      else: "Serves #{s}"
  end

  # A URL reads as its host ("From seriouseats.com"); a person or a book reads as said.
  defp source(nil), do: nil

  defp source(s) do
    case URI.parse(s) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        "From #{String.replace_prefix(host, "www.", "")}"

      _ ->
        "From #{s}"
    end
  end

  # ---------------------------------------------------------------------------------------------
  # Trackers

  @doc """
  The trackers book's body. `rows` is `App.Trackers.list/1` (most recently active first) and
  `entries_by_id` maps each tracker's id to its entries, newest first.
  """
  def trackers(rows, entries_by_id, now, tz) do
    %{
      items: Enum.map(rows, &tracker(&1, Map.get(entries_by_id, &1.tracker.id, []), now, tz)),
      empty: "No trackers yet.",
      hint: "Try: “Henry, log a headache, about a 6.”"
    }
  end

  @doc """
  One tracker: the list row (`label`, `unit`, `count`, `last`) and its detail: the last
  #{@window_days} days as one point per local day (`series`, oldest first, same point shape as
  the thread's tracker card), headline `stats` and top `tags` over that window, and the newest
  #{@recent_cap} entries (`recent`). `row` is one element of `App.Trackers.list/1`; `entries`
  is every entry on it, newest first.
  """
  def tracker(%{tracker: t, count: total, last_entry: last}, entries, now, tz) do
    unit = unit_suffix(t.unit)
    today = Trackers.local_date(now, tz)
    from = Date.add(today, 1 - @window_days)

    window =
      Enum.filter(entries, &(Date.compare(Trackers.local_date(&1.recorded_at, tz), from) != :lt))

    stats = Trackers.stats(window, tz)

    %{
      id: t.id,
      label: upcase_first(t.label),
      unit: t.unit,
      count: count(total, "entry", "entries"),
      last: last_line(last, unit, today, tz),
      range: "Last #{@window_days} days",
      series: series(window, from, today, tz, unit),
      axis_from: Calendar.strftime(from, "%b %-d"),
      axis_to: "Today",
      stats: if(window == [], do: [], else: stats_rows(stats, unit)),
      tags: Enum.map(Enum.take(stats.top_tags, @tags_cap), &tag_row/1),
      recent: entries |> Enum.take(@recent_cap) |> Enum.map(&entry_row(&1, unit, today, tz)),
      more: if(total > @recent_cap, do: "Showing the latest #{@recent_cap} of #{total}"),
      quiet: if(window == [], do: "Nothing logged in the last #{@window_days} days.")
    }
  end

  defp last_line(nil, _unit, _today, _tz), do: "No entries yet"

  defp last_line(entry, unit, today, tz) do
    day = Trackers.local_date(entry.recorded_at, tz)

    when_ =
      case Date.diff(today, day) do
        0 -> "Today"
        1 -> "Yesterday"
        n when n in 2..13 -> "#{n} days ago"
        _ -> short_date(day, today)
      end

    join([when_, value(entry.value, unit)])
  end

  # One point per local day, oldest first: `count` entries that day and `value`, the day's
  # worst (max) when any entry carried one. The highest day (the latest on a tie) carries its
  # value as `peak` for the chart to call out. `tip` is what the chart reads out when that day
  # is touched.
  defp series(window, from, today, tz, unit) do
    by_day = Enum.group_by(window, &Trackers.local_date(&1.recorded_at, tz))

    Date.range(from, today)
    |> Enum.map(fn date ->
      day = Map.get(by_day, date, [])
      values = for %{value: v} <- day, is_number(v), do: v
      worst = if values != [], do: Trackers.display_number(Enum.max(values))

      %{
        label: Calendar.strftime(date, "%b %-d"),
        count: length(day),
        value: worst,
        peak: nil,
        tip: tip(date, today, length(day), worst, unit)
      }
    end)
    |> mark_peak()
  end

  # "Sat, Oct 10 · 6" / "Yesterday · up to 8 · 2 entries" / "Today · 1 entry" / "… · Nothing logged"
  defp tip(date, today, n, worst, unit) do
    day =
      case Date.diff(today, date) do
        0 -> "Today"
        1 -> "Yesterday"
        _ -> Calendar.strftime(date, "%a, %b %-d")
      end

    what =
      case {n, worst} do
        {0, _} -> "Nothing logged"
        {1, nil} -> "1 entry"
        {n, nil} -> "#{n} entries"
        {1, v} -> value(v, unit)
        {n, v} -> "up to #{value(v, unit)} · #{n} entries"
      end

    "#{day} · #{what}"
  end

  defp mark_peak(points) do
    valued = for {%{value: v} = p, i} <- Enum.with_index(points), v != nil, do: {p, i}

    case Enum.reverse(valued) do
      [] ->
        points

      latest_first ->
        {peak, i} = Enum.max_by(latest_first, fn {p, _i} -> p.value end)
        List.replace_at(points, i, %{peak | peak: number(peak.value)})
    end
  end

  # A measured tracker headlines its average and range; a habit (no values) its entries, the
  # distinct days when that differs, and its best streak.
  defp stats_rows(%{value: %{avg: avg, min: min, max: max}} = stats, unit) do
    [
      %{label: "Average", value: with_unit(number(avg), unit)},
      %{label: "Range", value: with_unit(span(min, max), unit)},
      %{label: "Entries", value: number(stats.count)}
    ]
  end

  defp stats_rows(stats, _unit) do
    days = stats.days_with_entries
    streak = get_in(stats, [:longest_streak, :days])

    [
      %{label: "Entries", value: number(stats.count)},
      if(days != stats.count, do: %{label: "Days", value: number(days)}),
      if(is_integer(streak) and streak >= 2, do: %{label: "Best streak", value: "#{streak} days"})
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp tag_row(%{tag: tag, count: n}), do: %{tag: tag, tally: if(n > 1, do: "×#{n}")}

  defp entry_row(e, unit, today, tz) do
    local = Trackers.local(e.recorded_at, tz)
    date = DateTime.to_date(local)

    day =
      case Date.diff(today, date) do
        0 -> "Today"
        1 -> "Yesterday"
        _ when date.year == today.year -> Calendar.strftime(date, "%a, %b %-d")
        _ -> Calendar.strftime(date, "%b %-d, %Y")
      end

    %{
      day: day,
      time: clock(local),
      value: value(e.value, unit),
      note: e.note,
      tags: e.tags || []
    }
  end

  defp value(v, unit) when is_number(v), do: with_unit(number(v), unit)
  defp value(_v, _unit), do: nil

  # A unit that reads as a suffix ("lb", "hours") rides on the numbers; a scale description
  # ("pain 1-10") does not, because the values already say it.
  defp unit_suffix(unit) when is_binary(unit) do
    unit = String.trim(unit)
    if unit != "" and String.length(unit) <= 8 and not (unit =~ ~r/\d/), do: unit
  end

  defp unit_suffix(_), do: nil

  defp with_unit(s, nil), do: s
  defp with_unit(s, unit), do: "#{s} #{unit}"

  defp span(same, same), do: number(same)
  defp span(min, max), do: "#{number(min)}–#{number(max)}"

  defp number(n), do: n |> Trackers.display_number() |> to_string()

  # ---------------------------------------------------------------------------------------------
  # Routines

  @doc "The routines book's body: its rows (in the caller's order) and its empty state."
  def routines(routines, now, tz) do
    %{
      items: Enum.map(routines, &routine(&1, now, tz)),
      empty: "No routines yet.",
      hint:
        "Try: “Henry, when I say good night, turn off the lights and tell me what's first tomorrow.”"
    }
  end

  @doc """
  One routine: its name, the phrases that run it (`say` — the name first, then every trigger
  that does not merely repeat it), its steps as written, when it last ran, and the
  confirmation its Delete shows.
  """
  def routine(%Routine{} = r, now, tz) do
    %{
      id: r.id,
      name: r.label,
      say: Enum.uniq_by([r.label | r.triggers], &Routines.match_key/1),
      steps: r.steps,
      last_run: last_run(r.last_run_at, now, tz),
      delete_confirm: "Delete the “#{r.label}” routine? This can't be undone."
    }
  end

  defp last_run(nil, _now, _tz), do: "Not run yet"

  defp last_run(at, now, tz) do
    today = Trackers.local_date(now, tz)
    local = Trackers.local(at, tz)
    date = DateTime.to_date(local)

    case Date.diff(today, date) do
      0 -> "Ran today, #{clock(local)}"
      1 -> "Ran yesterday"
      n when n in 2..13 -> "Ran #{n} days ago"
      _ -> "Ran #{short_date(date, today)}"
    end
  end

  # ---------------------------------------------------------------------------------------------
  # Shared

  defp count(1, one, _many), do: "1 #{one}"
  defp count(n, _one, many), do: "#{n} #{many}"

  defp short_date(%Date{year: y} = d, %Date{year: y}), do: Calendar.strftime(d, "%b %-d")
  defp short_date(d, _today), do: Calendar.strftime(d, "%b %-d, %Y")

  # "2:15 PM"
  defp clock(local), do: Calendar.strftime(local, "%-I:%M %p")

  defp join(parts) do
    case Enum.reject(parts, &(&1 in [nil, ""])) do
      [] -> nil
      kept -> Enum.join(kept, " · ")
    end
  end

  defp upcase_first(nil), do: nil

  defp upcase_first(s) do
    {first, rest} = String.split_at(s, 1)
    String.upcase(first) <> rest
  end
end
