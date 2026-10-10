defmodule App.Tools.Trackers do
  @moduledoc """
  The tracker-book tool: log data points by voice ("I've got a headache, maybe a 6 — I skipped
  lunch"), read a range back with local dates + a stats summary so the brain can reason about
  patterns ("how have my headaches been this month?"), list trackers, undo the last entry
  ("scratch that"), and delete a whole tracker. Always the calling user's own, private data
  (`App.Trackers` is scoped by `user_id`; nothing here is household-shared).

  Time contract (same as reminders' `due_at`): the brain resolves relative times itself and
  passes absolute ISO8601 UTC. `get_tracker_entries` also accepts a plain ISO date for
  `since`/`until`, read as a whole LOCAL day. Every result is JSON-ready: times go out as UTC
  ISO strings PLUS local `local_date`/`weekday`/`local_time` in the instance timezone, so the
  brain never has to convert to talk about "Monday afternoon".
  """
  @behaviour App.Tools.Tool

  alias App.Trackers

  # Newest-first cap on returned entries; stats always cover the whole range.
  @max_entries 100
  @default_days 30
  # A recorded_at this far ahead of now is a bad conversion, not a data point.
  @future_tolerance_s 600

  @impl true
  def prompt do
    "You keep private trackers for the user (headaches, weight, sleep hours, back pain, habits " <>
      "like \"no soda today\"): when they report something they track, or ask to start " <>
      "tracking something, log it with log_tracker_entry — for pain or symptoms ask once for " <>
      "a 1–10 number only if they didn't give one, put likely triggers or context they mention " <>
      "(\"skipped lunch\", \"poor sleep\", \"coffee\") in tags, and confirm in a few words " <>
      "(\"Logged — headache, 6.\"); if they say \"scratch that\" right after, call " <>
      "undo_tracker_entry. For history or pattern questions (\"how have my headaches been " <>
      "this month? any pattern?\"), fetch with get_tracker_entries and reason honestly over " <>
      "its dates, weekdays, tags, notes and stats — say plainly when the sample is too small " <>
      "to mean much, and be genuinely useful without dressing it up as medical advice. " <>
      "list_trackers shows what they track; delete_tracker erases a tracker and ALL its " <>
      "history, so confirm with the user before calling it."
  end

  @impl true
  def bridge(_name), do: []

  @impl true
  def declarations do
    [
      %{
        name: "log_tracker_entry",
        description:
          "Log one data point on one of the user's trackers (headaches, weight, sleep, habits…). " <>
            "The tracker is created on first use; names match loosely (\"headache\" = " <>
            "\"my headaches\"). Only the tracker is required — the event itself is a data point.",
        parameters: %{
          type: "object",
          properties: %{
            tracker: %{
              type: "string",
              description:
                "What is being tracked, short and reusable: \"headache\", \"weight\", " <>
                  "\"sleep\", \"no soda\"."
            },
            value: %{
              type: "number",
              description:
                "The measurement, if any: pain 1–10, pounds, hours slept. Omit if none was given."
            },
            note: %{
              type: "string",
              description:
                "Free-form detail worth keeping (\"behind the eyes, came on at work\")."
            },
            tags: %{
              type: "array",
              items: %{type: "string"},
              description:
                "Short likely triggers/context the user mentioned, e.g. [\"skipped lunch\", " <>
                  "\"coffee\", \"poor sleep\"]."
            },
            recorded_at: %{
              type: "string",
              description:
                "When it happened, ISO8601 UTC (e.g. 2026-10-10T14:00:00Z), only if they said " <>
                  "it was earlier (\"yesterday afternoon\"). Omit for now."
            },
            unit: %{
              type: "string",
              description:
                "Only when starting a NEW tracker: its unit/scale (\"pain 1-10\", \"lb\", " <>
                  "\"hours\"). Ignored once the tracker has one."
            }
          },
          required: ["tracker"]
        }
      },
      %{
        name: "get_tracker_entries",
        description:
          "Fetch a tracker's entries (newest first, local dates + weekdays) with a stats " <>
            "summary (value min/avg/max, per-weekday and per-week counts, longest streak and " <>
            "gap, top tags) — for history and pattern questions. Defaults to the last 30 days.",
        parameters: %{
          type: "object",
          properties: %{
            tracker: %{type: "string", description: "Which tracker, e.g. \"headache\"."},
            since: %{
              type: "string",
              description:
                "Start of the range, ISO8601 UTC (or a plain date like 2026-09-01 for a whole " <>
                  "local day). Omit for 30 days before `until`."
            },
            until: %{
              type: "string",
              description:
                "End of the range, ISO8601 UTC (or a plain date, inclusive). Omit for now."
            }
          },
          required: ["tracker"]
        }
      },
      %{
        name: "list_trackers",
        description:
          "List the user's trackers with their unit, entry count and most recent entry.",
        parameters: %{type: "object", properties: %{}, required: []}
      },
      %{
        name: "undo_tracker_entry",
        description:
          "Undo the most recently logged entry on a tracker (\"scratch that\", \"that was " <>
            "wrong\"). The tracker itself stays.",
        parameters: %{
          type: "object",
          properties: %{
            tracker: %{type: "string", description: "Which tracker, e.g. \"headache\"."}
          },
          required: ["tracker"]
        }
      },
      %{
        name: "delete_tracker",
        description:
          "Delete a whole tracker and ALL of its history. Destructive — confirm with the user " <>
            "first.",
        parameters: %{
          type: "object",
          properties: %{
            tracker: %{type: "string", description: "Which tracker to delete."}
          },
          required: ["tracker"]
        }
      }
    ]
  end

  # --- execute ---------------------------------------------------------------------------------

  @impl true
  def execute(_name, _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — trackers unavailable, nothing saved"}}

  def execute("list_trackers", _args, ctx) do
    tz = App.Config.timezone()

    case Trackers.list(uid(ctx)) do
      [] ->
        {:ok, %{trackers: [], note: "no trackers yet"}}

      rows ->
        {:ok,
         %{
           trackers:
             Enum.map(rows, fn %{tracker: t, count: n, last_entry: last} ->
               %{
                 tracker: t.label,
                 unit: t.unit,
                 entries: n,
                 last_entry: last && entry_view(last, tz)
               }
             end)
         }}
    end
  end

  def execute(name, %{"tracker" => tracker} = args, ctx) when is_binary(tracker) do
    if Trackers.normalize(tracker) == nil,
      do: {:error, :invalid_tracker},
      else: run(name, tracker, args, uid(ctx))
  end

  def execute(_name, _args, _ctx), do: {:error, :missing_args}

  defp run("log_tracker_entry", tracker, args, user_id) do
    tz = App.Config.timezone()

    with {:ok, value} <- parse_value(args["value"]),
         {:ok, recorded_at} <- parse_recorded_at(args["recorded_at"]),
         {:ok, %{tracker: t, entry: entry, created: created}} <-
           Trackers.log(user_id, tracker, %{
             value: value,
             note: string_or_nil(args["note"]),
             tags: args["tags"],
             unit: string_or_nil(args["unit"]),
             recorded_at: recorded_at
           }) do
      {:ok,
       %{
         logged: true,
         tracker: t.label,
         created: created,
         unit: t.unit,
         entry: entry_view(entry, tz),
         total_entries: Trackers.count_entries(t)
       }}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_entry}
      {:error, :invalid_name} -> {:error, :invalid_tracker}
      {:error, _} = error -> error
    end
  end

  defp run("get_tracker_entries", tracker, args, user_id) do
    tz = App.Config.timezone()

    with {:ok, until} <- parse_bound(args["until"], :until, tz),
         until = until || DateTime.utc_now(),
         {:ok, since} <- parse_bound(args["since"], :since, tz),
         since = since || DateTime.add(until, -@default_days * 86_400, :second),
         :ok <- check_range(since, until) do
      case Trackers.entries(user_id, tracker, since, until) do
        {:error, :not_found} ->
          {:ok,
           %{
             note: "no tracker called \"#{tracker}\"",
             trackers: Enum.map(Trackers.list(user_id), & &1.tracker.label)
           }}

        {:ok, t, entries} ->
          {:ok, range_result(t, entries, since, until, tz)}
      end
    end
  end

  defp run("undo_tracker_entry", tracker, _args, user_id) do
    case Trackers.delete_last(user_id, tracker) do
      {:ok, t, entry} ->
        {:ok,
         %{
           tracker: t.label,
           undone: entry_view(entry, App.Config.timezone()),
           remaining: Trackers.count_entries(t)
         }}

      {:error, :not_found} ->
        {:ok, %{note: "no tracker called \"#{tracker}\" — nothing to undo"}}

      {:error, :empty} ->
        {:ok, %{note: "\"#{tracker}\" has no entries — nothing to undo"}}
    end
  end

  defp run("delete_tracker", tracker, _args, user_id) do
    case Trackers.delete_tracker(user_id, tracker) do
      {:ok, t, count} -> {:ok, %{deleted: t.label, entries_deleted: count}}
      {:error, :not_found} -> {:ok, %{note: "no tracker called \"#{tracker}\" — nothing deleted"}}
    end
  end

  defp run(_name, _tracker, _args, _user_id), do: {:error, :unknown_tool}

  defp range_result(tracker, entries, since, until, tz) do
    total = length(entries)
    shown = Enum.take(entries, @max_entries)

    result = %{
      tracker: tracker.label,
      unit: tracker.unit,
      timezone: tz,
      since: since |> Trackers.local_date(tz) |> Date.to_iso8601(),
      until: until |> Trackers.local_date(tz) |> Date.to_iso8601(),
      total: total,
      returned: length(shown),
      truncated: total > @max_entries,
      stats: Trackers.stats(entries, tz),
      entries: Enum.map(shown, &entry_view(&1, tz))
    }

    cond do
      total == 0 ->
        Map.put(result, :note, "no entries in this range")

      total > @max_entries ->
        Map.put(
          result,
          :note,
          "showing the newest #{@max_entries} of #{total} entries; stats cover all #{total}"
        )

      true ->
        result
    end
  end

  # --- views & parsing -------------------------------------------------------------------------

  @doc false
  def entry_view(entry, tz) do
    local = Trackers.local(entry.recorded_at, tz)

    %{
      recorded_at: entry.recorded_at |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      local_date: local |> DateTime.to_date() |> Date.to_iso8601(),
      weekday: Calendar.strftime(local, "%A"),
      local_time: Calendar.strftime(local, "%-I:%M %p"),
      value: Trackers.display_number(entry.value),
      note: entry.note,
      tags: entry.tags || []
    }
  end

  defp parse_value(nil), do: {:ok, nil}
  defp parse_value(v) when is_number(v), do: {:ok, v}

  defp parse_value(v) when is_binary(v) do
    case v |> String.trim() |> Float.parse() do
      {n, ""} -> {:ok, n}
      _ -> if String.trim(v) == "", do: {:ok, nil}, else: {:error, :invalid_value}
    end
  end

  defp parse_value(_), do: {:error, :invalid_value}

  defp parse_recorded_at(nil), do: {:ok, nil}
  defp parse_recorded_at(""), do: {:ok, nil}

  defp parse_recorded_at(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} ->
        if DateTime.diff(dt, DateTime.utc_now()) > @future_tolerance_s,
          do: {:error, :recorded_at_in_future},
          else: {:ok, dt}

      _ ->
        {:error, :invalid_recorded_at}
    end
  end

  defp parse_recorded_at(_), do: {:error, :invalid_recorded_at}

  # A range bound: a full ISO8601 datetime, or a plain date taken as a whole LOCAL day (since →
  # its first instant, until → its last). nil/"" = unbounded (the caller fills the default).
  defp parse_bound(nil, _which, _tz), do: {:ok, nil}
  defp parse_bound("", _which, _tz), do: {:ok, nil}

  defp parse_bound(s, which, tz) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      _ ->
        case Date.from_iso8601(s) do
          {:ok, date} -> {:ok, local_day_edge(date, which, tz)}
          _ -> {:error, bound_error(which)}
        end
    end
  end

  defp parse_bound(_s, which, _tz), do: {:error, bound_error(which)}

  defp bound_error(:since), do: :invalid_since
  defp bound_error(:until), do: :invalid_until

  defp local_day_edge(date, :since, tz), do: local_instant(date, ~T[00:00:00.000000], tz)
  defp local_day_edge(date, :until, tz), do: local_instant(date, ~T[23:59:59.999999], tz)

  defp local_instant(date, time, tz) do
    case DateTime.new(date, time, tz) do
      {:ok, dt} -> utc(dt)
      {:ambiguous, first, _second} -> utc(first)
      {:gap, _before, just_after} -> utc(just_after)
      {:error, _} -> DateTime.new!(date, time, "Etc/UTC")
    end
  end

  defp utc(dt), do: DateTime.shift_zone!(dt, "Etc/UTC")

  defp check_range(since, until) do
    if DateTime.compare(since, until) == :gt, do: {:error, :invalid_range}, else: :ok
  end

  defp string_or_nil(s) when is_binary(s), do: s
  defp string_or_nil(_), do: nil

  defp uid(%{user_id: uid}), do: uid
end
