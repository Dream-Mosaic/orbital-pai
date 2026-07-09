defmodule App.Tools.Calendar do
  @moduledoc """
  The calendar tools. `get_calendar_events` reads the user's connected Google accounts, fans out
  concurrently, merges + sorts events by start, tags each with its account label, and reports
  per-account failures (e.g. a token that needs reconnecting) without failing the whole call.
  `create_event` writes a new event to the user's default account (or a named one), confirm-first
  via the prompt. The brain resolves relative ranges using the 'current time' line in its prompt.
  """
  @behaviour App.Tools.Tool

  require Logger
  alias App.Google.{Accounts, Calendar, Connectors}

  @impl true
  def declarations do
    [
      %{
        name: "get_calendar_events",
        description:
          "Read the user's calendar events across their connected Google accounts, as ISO8601 UTC " <>
            "time_min/time_max. For a NAMED day or week (today, tomorrow, this week), ALWAYS use " <>
            "that whole period's boundaries — the START of the day/week to its END — never the " <>
            "current moment, so the same question asked twice is identical. Only use 'now' as " <>
            "time_min when the user explicitly asks what's NEXT or UPCOMING. The result's " <>
            "`accounts_read` lists every connected account that was checked (even ones with no " <>
            "events) — use it to answer which accounts are connected; an empty calendar is NOT " <>
            "the same as a disconnected account. Account names match case-insensitively.",
        parameters: %{
          type: "object",
          properties: %{
            time_min: %{
              type: "string",
              description:
                "Range start, ISO8601 UTC. For a named day/week use that period's START " <>
                  "(e.g. 00:00 local); only use 'now' for 'what's next/upcoming'."
            },
            time_max: %{
              type: "string",
              description: "Range end, ISO8601 UTC. For a named day/week use that period's END."
            },
            account: %{
              type: "string",
              description: "Limit to one connected account by email/label; omit for all."
            }
          },
          required: []
        }
      },
      %{
        name: "create_event",
        description:
          "Create a calendar event. First read the details back to the user and wait for them " <>
            "to confirm; only then call this. Writes to the user's default account unless " <>
            "`account` is given. Compute start/end from the current time as ISO8601 UTC.",
        parameters: %{
          type: "object",
          properties: %{
            summary: %{type: "string", description: "Event title."},
            start: %{
              type: "string",
              description: "Start, ISO8601 UTC date-time (timed) or YYYY-MM-DD (all-day)."
            },
            end: %{
              type: "string",
              description:
                "End, ISO8601. Optional — defaults to +1h (timed) / next day (all-day). For " <>
                  "all-day events the end date is EXCLUSIVE, so it must be at least start + 1 day."
            },
            all_day: %{type: "boolean", description: "True if start/end are dates."},
            location: %{type: "string", description: "Optional location."},
            account: %{
              type: "string",
              description: "Target account by email/label; omit for default."
            }
          },
          required: ["summary", "start"]
        }
      }
    ]
  end

  @impl true
  def cache_ttl("get_calendar_events"), do: 30_000
  def cache_ttl(_), do: nil

  @impl true
  def cache_invalidates("create_event"), do: ["get_calendar_events"]
  def cache_invalidates(_), do: []

  # The brain re-emits drifting time_min/time_max each turn (e.g. 04:59:59Z vs 05:00:00Z). Round them
  # to the minute in the cache key so the same "today" query asked twice in a row actually hits.
  @impl true
  def cache_key("get_calendar_events", args) do
    Map.new(args, fn
      {k, v} when k in ["time_min", "time_max"] -> {k, round_minute(v)}
      pair -> pair
    end)
  end

  def cache_key(_name, args), do: args

  defp round_minute(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        unix = DateTime.to_unix(dt)
        (round(unix / 60) * 60) |> DateTime.from_unix!() |> DateTime.to_iso8601()

      _ ->
        iso
    end
  end

  defp round_minute(other), do: other

  @impl true
  def bridge("get_calendar_events"),
    do: [
      "Checking your calendar, one moment.",
      "One sec, pulling up your calendar.",
      "Let me look at your calendar."
    ]

  def bridge("create_event"),
    do: ["Adding that to your calendar, one sec.", "Putting that on your calendar now."]

  def bridge(_), do: []

  @impl true
  def execute("get_calendar_events", _args, %{user_id: nil}),
    do: {:ok, %{events: [], errors: [], note: note(nil)}}

  def execute("get_calendar_events", args, %{user_id: user_id}) do
    filter = Map.get(args, "account")

    case select_accounts(user_id, filter) do
      [] ->
        {:ok, %{events: [], errors: [], note: note(filter)}}

      accounts ->
        accounts = ensure_fresh(user_id, accounts)
        opts = [time_min: time_min(args), time_max: time_max(args)]
        {events, errors} = gather(accounts, opts)
        # accounts_read tells the brain WHICH connected accounts were actually queried, so an
        # account with no events today isn't mistaken for "not connected" (it appears here even
        # when it contributes zero events).
        {:ok, %{events: events, errors: errors, accounts_read: Enum.map(accounts, & &1.label)}}
    end
  end

  def execute("create_event", _args, %{user_id: nil}),
    do: {:ok, %{note: note(nil)}}

  def execute("create_event", args, %{user_id: user_id}) do
    case resolve_target(user_id, Map.get(args, "account")) do
      {:error, note} ->
        {:ok, %{note: note}}

      {:ok, account} ->
        case Calendar.create_event(account, event_attrs(args)) do
          {:ok, created} ->
            {:ok, %{created: created}}

          {:error, :needs_write_access} ->
            {:ok, %{error: "needs_write_access", account: account.label}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # No name: prefer the default if it can write, else the sole writable account, else ask.
  defp resolve_target(user_id, nil) do
    writers = Accounts.accounts_with_write(user_id, :calendar)
    default = Accounts.default(user_id)

    cond do
      default && Connectors.can_write?(default, :calendar) ->
        {:ok, default}

      match?([_one], writers) ->
        {:ok, hd(writers)}

      writers == [] ->
        if Accounts.list(user_id) == [],
          do: {:error, "no Google accounts connected"},
          else: {:error, "no calendar with write access — connect one or grant write"}

      true ->
        {:error, "multiple writable calendars — name which account to use"}
    end
  end

  # Named: must exist and be able to write.
  defp resolve_target(user_id, filter) do
    case Enum.find(Accounts.list(user_id), &account_matches?(&1, filter)) do
      nil ->
        {:error, "no connected account matching #{inspect(filter)}"}

      account ->
        if Connectors.can_write?(account, :calendar),
          do: {:ok, account},
          else: {:error, "#{account.label} is read-only for calendar"}
    end
  end

  defp event_attrs(args) do
    all_day? = Map.get(args, "all_day", false) == true
    start = Map.get(args, "start")

    %{
      summary: Map.get(args, "summary"),
      start: start,
      end: Map.get(args, "end") || default_end(start, all_day?),
      all_day?: all_day?,
      location: Map.get(args, "location")
    }
  end

  defp default_end(start, true) do
    case Date.from_iso8601(start) do
      {:ok, d} -> d |> Date.add(1) |> Date.to_iso8601()
      _ -> start
    end
  end

  defp default_end(start, false) do
    case DateTime.from_iso8601(start) do
      {:ok, dt, _} -> dt |> DateTime.add(1, :hour) |> DateTime.to_iso8601()
      _ -> start
    end
  end

  defp select_accounts(user_id, nil), do: Accounts.accounts_with_read(user_id, :calendar)

  defp select_accounts(user_id, filter),
    do:
      Enum.filter(Accounts.accounts_with_read(user_id, :calendar), &account_matches?(&1, filter))

  # Match an account by email or label, case-INSENSITIVELY — the brain (and the user speaking it
  # aloud) routinely uppercases an address like "DAVE@example.com", which must still match the
  # stored lowercase "dave@example.com". Emails are effectively case-insensitive in practice.
  @doc false
  def account_matches?(account, filter) when is_binary(filter) do
    f = String.downcase(filter)
    String.downcase(account.email) == f or String.downcase(account.label) == f
  end

  def account_matches?(_account, _filter), do: false

  # Refresh each account's token SEQUENTIALLY before the concurrent fetch fan-out. When several
  # accounts have stale tokens, refreshing them inside the parallel fan-out makes them contend for
  # SQLite's single writer (busy_timeout makes the loser WAIT up to 5s), which pushes one account
  # past the fan-out's 7s timeout — so "one of three always errored", rotating which one. Doing the
  # refreshes one at a time (then reloading the freshly-persisted structs) means the parallel part
  # is only fast, read-only calendar fetches. A genuinely-broken token still errors in `gather`,
  # isolated to its own account and logged.
  defp ensure_fresh(user_id, accounts) do
    Enum.each(accounts, &Accounts.valid_access_token/1)
    ids = MapSet.new(accounts, & &1.id)
    Enum.filter(Accounts.list(user_id), &MapSet.member?(ids, &1.id))
  end

  defp gather(accounts, opts) do
    # ordered: true (the default) keeps results aligned 1:1 with `accounts`, so we can zip them
    # back together and still know which account a killed/timed-out task belonged to.
    results =
      accounts
      |> Task.async_stream(fn a -> Calendar.list_events(a, opts) end,
        max_concurrency: 5,
        timeout: 7_000,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    {events, errors} =
      accounts
      |> Enum.zip(results)
      |> Enum.reduce({[], []}, fn
        {_a, {:ok, {:ok, evs}}}, {acc_evs, errs} ->
          {[evs | acc_evs], errs}

        {a, {:ok, {:error, reason}}}, {acc_evs, errs} ->
          Logger.warning("[calendar] #{a.label} read failed: #{inspect(reason)}")
          {acc_evs, [%{account: a.label, reason: error_reason(reason)} | errs]}

        {a, {:exit, _reason}}, {acc_evs, errs} ->
          Logger.warning("[calendar] #{a.label} read timed out (>7s)")
          {acc_evs, [%{account: a.label, reason: "timeout"} | errs]}
      end)

    events = events |> List.flatten() |> Enum.sort_by(&(&1.start || ""))
    errors = Enum.reverse(errors)

    # Fan-out summary — proves the cold-start path recovered: after the :pool_not_available retry
    # fix this should read "N accounts, 0 errors" on the first call, where it used to lose one.
    Logger.info(
      "[calendar] fan-out: #{length(accounts)} accounts, #{length(events)} events, " <>
        "#{length(errors)} errors"
    )

    {events, errors}
  end

  defp error_reason(:needs_reconnect), do: "needs_reconnect"
  defp error_reason(other), do: inspect(other)

  defp note(nil), do: "no Google accounts connected"
  defp note(filter), do: "no connected account matching #{inspect(filter)}"

  defp time_min(args), do: Map.get(args, "time_min") || iso(now())
  defp time_max(args), do: Map.get(args, "time_max") || iso(DateTime.add(now(), 24, :hour))

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp iso(dt), do: DateTime.to_iso8601(dt)
end
