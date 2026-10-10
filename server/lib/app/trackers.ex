defmodule App.Trackers do
  @moduledoc """
  The tracker book: append-only, per-user time series logged by voice ("I've got a headache,
  maybe a 6 — I skipped lunch") so the brain can look for patterns later ("how have my
  headaches been this month?"). Generic on purpose — headaches first, but weight, sleep hours,
  back pain and habits ("no soda today") are the same shape.

  PRIVATE per user, always: every query is scoped by `user_id` and nothing here is household
  shared — one person's symptoms are never another's data.

  A tracker is created implicitly by its first entry. Names match loosely (`normalize/1` +
  `same_name?/2`): case-insensitive, "my"/"the" and a trailing "tracker" ignored, and
  singular/plural collide ("headache" / "my headaches"), so the brain never has to remember the
  exact name it used last week.
  """
  import Ecto.Query
  alias App.Repo
  alias App.Trackers.{Entry, Tracker}

  @max_tags 10
  @max_tag_length 60
  # `by_week` keeps at most this many (most recent) weeks so a years-long range can't balloon
  # the brain's tool result.
  @max_weeks 26
  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  # ---------------------------------------------------------------------------------------------
  # Names

  @doc """
  The match key for a spoken tracker name, or nil when nothing is left: lowercased, trimmed,
  whitespace collapsed, trailing punctuation dropped, a leading "my"/"the"/"a"/"an" and a
  trailing "tracker"/"log" removed, and the last word singularized ("Headaches" → "headache",
  "allergies" → "allergy"). Stored as `Tracker.name` (unique per user).
  """
  def normalize(name) when is_binary(name) do
    case clean(name) do
      nil -> nil
      cleaned -> singular(String.downcase(cleaned))
    end
  end

  def normalize(_), do: nil

  # The name as the user said it, minus the possessive/article prefix and "tracker" suffix —
  # case kept, not singularized. nil when nothing is left.
  defp clean(name) do
    words =
      name
      |> String.replace(~r/[.!?,;:]+\s*$/u, "")
      |> String.split(~r/\s+/u, trim: true)
      |> drop_prefix()
      |> drop_suffix()

    case words do
      [] -> nil
      words -> Enum.join(words, " ")
    end
  end

  defp drop_prefix([first | rest]) do
    if String.downcase(first) in ~w(my the a an), do: rest, else: [first | rest]
  end

  defp drop_prefix([]), do: []

  defp drop_suffix(words) do
    case List.last(words) do
      nil ->
        []

      last ->
        if String.downcase(last) in ~w(tracker log tracking),
          do: Enum.drop(words, -1),
          else: words
    end
  end

  # Naive English singular of the last word (only the suffix changes): -ies → -y, -s → "" (not -ss/-us/-is).
  defp singular(s) do
    cond do
      String.length(s) > 4 and String.ends_with?(s, "ies") ->
        String.slice(s, 0..-4//1) <> "y"

      String.length(s) > 3 and String.ends_with?(s, "s") and
          not String.ends_with?(s, ["ss", "us", "is"]) ->
        String.slice(s, 0..-2//1)

      true ->
        s
    end
  end

  # Keys are already singular, but the naive rule can't fold "-es" plurals: "matches" keys as
  # "matche" while "match" keys as "match" (same for glasses/glass, boxes/box). A key ending in
  # ch/sh/ss/x/z + "e" therefore also stands for its "e"-less form, so either order collides.
  defp forms(key) do
    if Regex.match?(~r/(ch|sh|ss|x|z)e$/u, key),
      do: [key, String.slice(key, 0..-2//1)],
      else: [key]
  end

  @doc false
  def same_name?(a, b) when is_binary(a) and is_binary(b),
    do: a == b or Enum.any?(forms(a), &(&1 in forms(b)))

  @doc """
  `user_id`'s tracker for a spoken name (exact key first, then the loose plural match), or nil.
  """
  def find(user_id, name), do: find_key(user_id, normalize(name))

  defp find_key(_user_id, nil), do: nil

  defp find_key(user_id, key) do
    Repo.get_by(Tracker, user_id: user_id, name: key) ||
      Tracker
      |> where([t], t.user_id == ^user_id)
      |> order_by([t], asc: t.id)
      |> Repo.all()
      |> Enum.find(&same_name?(&1.name, key))
  end

  # ---------------------------------------------------------------------------------------------
  # Writes

  @doc """
  Log one entry on `user_id`'s tracker `name`, creating the tracker on first use. `attrs` is
  ATOM-keyed, all optional: `value` (number), `note`, `tags` (list of short strings —
  trimmed, lowercased, de-duplicated), `recorded_at` (`DateTime`, default now) and `unit`
  (applied only when the tracker has none yet — never overwritten).

  Returns `{:ok, %{tracker, entry, created}}`, `{:error, :invalid_name}` for a blank name, or
  `{:error, changeset}`.
  """
  def log(user_id, name, attrs) do
    case {clean_name(name), normalize(name)} do
      {nil, _} ->
        {:error, :invalid_name}

      {_, nil} ->
        {:error, :invalid_name}

      {label, key} ->
        Repo.transaction(fn ->
          with {:ok, tracker, created} <- find_or_create(user_id, key, label, attrs[:unit]),
               {:ok, entry} <- insert_entry(tracker, attrs) do
            %{tracker: tracker, entry: entry, created: created}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
    end
  end

  defp clean_name(name) when is_binary(name), do: clean(name)
  defp clean_name(_), do: nil

  defp find_or_create(user_id, key, label, unit) do
    case find_key(user_id, key) do
      nil ->
        %Tracker{}
        |> Tracker.changeset(%{user_id: user_id, name: key, label: label, unit: blank_nil(unit)})
        |> Repo.insert()
        |> case do
          {:ok, tracker} -> {:ok, tracker, true}
          error -> error
        end

      %Tracker{unit: nil} = tracker ->
        case blank_nil(unit) do
          nil ->
            {:ok, tracker, false}

          unit ->
            with {:ok, t} <- tracker |> Tracker.changeset(%{unit: unit}) |> Repo.update(),
                 do: {:ok, t, false}
        end

      tracker ->
        {:ok, tracker, false}
    end
  end

  defp insert_entry(tracker, attrs) do
    %Entry{}
    |> Entry.changeset(%{
      tracker_id: tracker.id,
      recorded_at: to_usec(attrs[:recorded_at] || DateTime.utc_now()),
      value: attrs[:value],
      note: blank_nil(attrs[:note]),
      tags: normalize_tags(attrs[:tags])
    })
    |> Repo.insert()
  end

  @doc false
  def normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase() |> String.slice(0, @max_tag_length)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@max_tags)
  end

  def normalize_tags(tag) when is_binary(tag), do: normalize_tags([tag])
  def normalize_tags(_), do: []

  @doc """
  Undo ("scratch that"): delete the most recently LOGGED entry on `user_id`'s tracker — by
  insertion order, not `recorded_at`, so a just-backdated entry is the one removed. The
  tracker itself stays. `{:ok, tracker, entry}` | `{:error, :not_found | :empty}`.
  """
  def delete_last(user_id, name) do
    with %Tracker{} = tracker <- find(user_id, name) || {:error, :not_found},
         %Entry{} = entry <- last_logged(tracker) || {:error, :empty},
         {:ok, deleted} <- Repo.delete(entry) do
      {:ok, tracker, deleted}
    end
  end

  defp last_logged(tracker) do
    Entry
    |> where([e], e.tracker_id == ^tracker.id)
    |> order_by([e], desc: e.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Delete `user_id`'s tracker and every entry on it. `{:ok, tracker, entries_deleted}` |
  `{:error, :not_found}`.
  """
  def delete_tracker(user_id, name) do
    with %Tracker{} = tracker <- find(user_id, name) || {:error, :not_found} do
      count = count_entries(tracker)
      {:ok, deleted} = Repo.delete(tracker)
      {:ok, deleted, count}
    end
  end

  # ---------------------------------------------------------------------------------------------
  # Reads

  @doc """
  The entries on `user_id`'s tracker `name` recorded within `[since, until]` (inclusive; nil =
  unbounded), NEWEST first. `{:ok, tracker, entries}` | `{:error, :not_found}`.
  """
  def entries(user_id, name, since, until) do
    case find(user_id, name) do
      nil ->
        {:error, :not_found}

      tracker ->
        entries =
          Entry
          |> where([e], e.tracker_id == ^tracker.id)
          |> since_bound(since)
          |> until_bound(until)
          |> order_by([e], desc: e.recorded_at, desc: e.id)
          |> Repo.all()

        {:ok, tracker, entries}
    end
  end

  defp since_bound(q, nil), do: q
  defp since_bound(q, %DateTime{} = dt), do: where(q, [e], e.recorded_at >= ^to_usec(dt))

  defp until_bound(q, nil), do: q
  defp until_bound(q, %DateTime{} = dt), do: where(q, [e], e.recorded_at <= ^to_usec(dt))

  @doc """
  Every tracker `user_id` has, as `%{tracker, count, last_entry}` (`last_entry` = latest by
  `recorded_at`, nil when empty), most recently active first.
  """
  def list(user_id) do
    trackers = Tracker |> where([t], t.user_id == ^user_id) |> Repo.all()
    ids = Enum.map(trackers, & &1.id)

    counts =
      Entry
      |> where([e], e.tracker_id in ^ids)
      |> group_by([e], e.tracker_id)
      |> select([e], {e.tracker_id, count(e.id)})
      |> Repo.all()
      |> Map.new()

    trackers
    |> Enum.map(fn t ->
      %{tracker: t, count: Map.get(counts, t.id, 0), last_entry: latest(t)}
    end)
    |> Enum.sort_by(&activity_key/1, :desc)
  end

  defp latest(tracker) do
    Entry
    |> where([e], e.tracker_id == ^tracker.id)
    |> order_by([e], desc: e.recorded_at, desc: e.id)
    |> limit(1)
    |> Repo.one()
  end

  # Most recent entry first; empty trackers last (newest-created first among them).
  defp activity_key(%{last_entry: nil, tracker: t}), do: {0, 0, t.id}

  defp activity_key(%{last_entry: e, tracker: t}),
    do: {1, DateTime.to_unix(e.recorded_at, :microsecond), t.id}

  @doc "How many entries `tracker` has."
  def count_entries(%Tracker{id: id}) do
    Entry |> where([e], e.tracker_id == ^id) |> select([e], count(e.id)) |> Repo.one()
  end

  # ---------------------------------------------------------------------------------------------
  # Stats (pure)

  @doc """
  A modest, honest summary of `entries` (any order) for pattern questions, bucketed by LOCAL
  date in `tz`. JSON-ready (strings and numbers only; integral numbers render as integers):

    * `count`, `days_with_entries`, `first_date`/`last_date` (local ISO dates)
    * `value` — `%{count, min, max, avg}` over entries that have a value (nil if none)
    * `by_weekday` — all seven days Monday-first: `%{weekday, count, avg_value}`
    * `by_week` — Monday-start weeks from first to last, empty weeks included, at most the
      last #{@max_weeks}: `%{week_of, count, avg_value}`
    * `longest_streak` — most consecutive days with an entry: `%{days, from, to}`
    * `longest_gap` — most entry-free days between two entries: `%{days, from, to}` (nil with
      fewer than two distinct days)
    * `top_tags` — up to 5 `%{tag, count}`, by count then alphabetically
  """
  def stats(entries, tz \\ App.Config.timezone()) do
    local = Enum.map(entries, fn e -> {local_date(e.recorded_at, tz), e} end)
    dates = local |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort(Date)

    %{
      count: length(entries),
      days_with_entries: length(dates),
      first_date: iso(List.first(dates)),
      last_date: iso(List.last(dates)),
      value: value_summary(entries),
      by_weekday: by_weekday(local),
      by_week: by_week(local, dates),
      longest_streak: longest_streak(dates),
      longest_gap: longest_gap(dates),
      top_tags: top_tags(entries)
    }
  end

  defp value_summary(entries) do
    case values(entries) do
      [] ->
        nil

      vs ->
        %{
          count: length(vs),
          min: display_number(Enum.min(vs)),
          max: display_number(Enum.max(vs)),
          avg: avg(vs)
        }
    end
  end

  defp values(entries), do: for(%{value: v} <- entries, is_number(v), do: v)

  defp avg([]), do: nil
  defp avg(vs), do: display_number(Float.round(Enum.sum(vs) / length(vs), 2))

  defp by_weekday(local) do
    grouped = Enum.group_by(local, fn {d, _} -> Date.day_of_week(d) end, &elem(&1, 1))

    @weekdays
    |> Enum.with_index(1)
    |> Enum.map(fn {name, dow} ->
      es = Map.get(grouped, dow, [])
      %{weekday: name, count: length(es), avg_value: avg(values(es))}
    end)
  end

  defp by_week(_local, []), do: []

  defp by_week(local, dates) do
    grouped = Enum.group_by(local, fn {d, _} -> Date.beginning_of_week(d) end, &elem(&1, 1))
    first = Date.beginning_of_week(List.first(dates))
    last = Date.beginning_of_week(List.last(dates))

    Date.range(first, last, 7)
    |> Enum.map(fn week ->
      es = Map.get(grouped, week, [])
      %{week_of: iso(week), count: length(es), avg_value: avg(values(es))}
    end)
    |> Enum.take(-@max_weeks)
  end

  # Runs of consecutive dates (dates sorted + unique); the longest, earliest on a tie.
  defp longest_streak([]), do: nil

  defp longest_streak([first | rest]) do
    {best, cur} =
      Enum.reduce(rest, {{first, first}, {first, first}}, fn d, {best, {from, to}} ->
        cur = if Date.diff(d, to) == 1, do: {from, d}, else: {d, d}
        {longer(best, cur), cur}
      end)

    {from, to} = longer(best, cur)
    %{days: Date.diff(to, from) + 1, from: iso(from), to: iso(to)}
  end

  defp longer({bf, bt} = best, {cf, ct} = cur),
    do: if(Date.diff(ct, cf) > Date.diff(bt, bf), do: cur, else: best)

  defp longest_gap(dates) when length(dates) < 2, do: nil

  defp longest_gap(dates) do
    {from, to} =
      dates
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> {a, b} end)
      |> Enum.reduce(fn {a, b} = pair, {ba, bb} = best ->
        if Date.diff(b, a) > Date.diff(bb, ba), do: pair, else: best
      end)

    %{days: Date.diff(to, from) - 1, from: iso(from), to: iso(to)}
  end

  defp top_tags(entries) do
    entries
    |> Enum.flat_map(fn e -> e.tags |> List.wrap() |> normalize_tags() end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {tag, n} -> {-n, tag} end)
    |> Enum.take(5)
    |> Enum.map(fn {tag, n} -> %{tag: tag, count: n} end)
  end

  # ---------------------------------------------------------------------------------------------
  # Helpers

  @doc false
  def local_date(%DateTime{} = dt, tz), do: dt |> local(tz) |> DateTime.to_date()

  @doc false
  def local(%DateTime{} = dt, tz) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, local} -> local
      _ -> dt
    end
  end

  @doc "A number for display/JSON: integral floats become integers (6.0 → 6); nil passes."
  def display_number(nil), do: nil
  def display_number(n) when is_integer(n), do: n

  def display_number(n) when is_float(n) do
    if n == Float.round(n), do: trunc(n), else: n
  end

  defp iso(nil), do: nil
  defp iso(%Date{} = d), do: Date.to_iso8601(d)

  # :utc_datetime_usec wants UTC at microsecond precision 6 (an ISO string without fractional
  # seconds parses with precision 0).
  defp to_usec(%DateTime{} = dt) do
    %DateTime{microsecond: {us, _}} = utc = DateTime.shift_zone!(dt, "Etc/UTC")
    %{utc | microsecond: {us, 6}}
  end

  defp blank_nil(nil), do: nil

  defp blank_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      t -> t
    end
  end

  defp blank_nil(_), do: nil
end
