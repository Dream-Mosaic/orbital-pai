defmodule App.Reminders do
  @moduledoc """
  Local reminders: create, list, find-due, and acknowledge. Times are stored UTC. Persistence
  + queries, plus a thin notify seam: create/acknowledge/delete broadcast `{:reminders_changed}`
  on `"reminders:<user_id>"` so the LiveView panel stays live (same pattern as `App.Memory`).
  Household (shared) rows also notify `"reminders:household"` so every member's panel updates.
  The `App.Reminders.Scheduler` drives firing (and broadcasts `{:reminder_due, r}`).
  """
  import Ecto.Query
  alias App.Repo
  alias App.Reminders.Reminder

  def create(attrs) do
    case %Reminder{} |> Reminder.changeset(attrs) |> Repo.insert() do
      {:ok, r} ->
        broadcast_changed(r.user_id, r.household)
        {:ok, r}

      other ->
        other
    end
  end

  def delete(%Reminder{} = r) do
    case Repo.delete(r) do
      {:ok, deleted} ->
        broadcast_changed(deleted.user_id, deleted.household)
        {:ok, deleted}

      other ->
        other
    end
  end

  @doc "Mark a fired reminder as spoken/acknowledged. No-op on an un-persisted struct."
  def acknowledge(%Reminder{id: nil}), do: :ok

  def acknowledge(%Reminder{} = r) do
    case r |> Reminder.changeset(%{acknowledged_at: now()}) |> Repo.update() do
      {:ok, updated} ->
        broadcast_changed(updated.user_id, updated.household)
        {:ok, updated}

      other ->
        other
    end
  end

  @doc "Stamp a reminder as spoken by Henry (delivered) — it stays PENDING until the human acks."
  def mark_delivered(%Reminder{id: nil}), do: :ok

  def mark_delivered(%Reminder{} = r) do
    case r |> Reminder.changeset(%{delivered_at: now()}) |> Repo.update() do
      {:ok, updated} ->
        broadcast_changed(updated.user_id, updated.household)
        {:ok, updated}

      other ->
        other
    end
  end

  def list_upcoming(user_id) do
    now = now()

    Reminder
    |> where(
      [r],
      (r.user_id == ^user_id or r.household == true) and is_nil(r.fired_at) and r.due_at >= ^now
    )
    |> order_by([r], asc: r.due_at, asc: r.id)
    |> Repo.all()
  end

  @doc "Fired but not yet spoken/acknowledged — the panel's 'needs your attention' list."
  def list_unacknowledged(user_id) do
    Reminder
    |> where(
      [r],
      (r.user_id == ^user_id or r.household == true) and not is_nil(r.fired_at) and
        is_nil(r.acknowledged_at)
    )
    |> order_by([r], desc: r.fired_at, desc: r.id)
    |> Repo.all()
  end

  @doc """
  The user's best-matching PENDING (fired, un-acked) reminder for a spoken phrase — own OR household.
  Matches case-insensitively when the phrase is contained in the body or vice versa; most recently
  fired wins ties. nil when nothing matches (so the brain can say it couldn't find it).
  """
  def find_pending(user_id, phrase) when is_binary(phrase) do
    p = phrase |> String.downcase() |> String.trim()

    if p == "" do
      nil
    else
      user_id
      |> list_unacknowledged()
      |> Enum.filter(fn r ->
        b = String.downcase(r.body)
        String.contains?(b, p) or String.contains?(p, b)
      end)
      |> Enum.sort_by(& &1.fired_at, {:desc, DateTime})
      |> List.first()
    end
  end

  def find_pending(_user_id, _phrase), do: nil

  @doc """
  The user's best-matching ALREADY-ACKNOWLEDGED reminder for a phrase — own OR household. Same
  matching as `find_pending/2`, but over fired + acknowledged rows, so the ack tool can tell
  "already cleared" apart from "never existed" (else the brain confabulates a lost reminder when it
  finds nothing pending). Most recently acknowledged wins; nil when nothing matches.
  """
  def find_acknowledged(user_id, phrase) when is_binary(phrase) do
    p = phrase |> String.downcase() |> String.trim()

    if p == "" do
      nil
    else
      Reminder
      |> where(
        [r],
        (r.user_id == ^user_id or r.household == true) and not is_nil(r.fired_at) and
          not is_nil(r.acknowledged_at)
      )
      |> Repo.all()
      |> Enum.filter(fn r ->
        b = String.downcase(r.body)
        String.contains?(b, p) or String.contains?(p, b)
      end)
      |> Enum.sort_by(& &1.acknowledged_at, {:desc, DateTime})
      |> List.first()
    end
  end

  def find_acknowledged(_user_id, _phrase), do: nil

  # weekday codes for weekly byday, mapped to Date.day_of_week/1 ISO numbers (Mon=1..Sun=7).
  @day_codes %{"mon" => 1, "tue" => 2, "wed" => 3, "thu" => 4, "fri" => 5, "sat" => 6, "sun" => 7}

  @doc """
  The single occurrence strictly after `due_at` for a recurrence rule, in UTC — or nil when the
  series is exhausted (`remaining <= 1`: this firing was the last; or the computed next lands
  after the inclusive `until`; or the rule is nil/unusable). Pure and DST-safe: the calendar
  step is taken on the LOCAL wall-clock (shift into `tz`, step the local date, keep the local
  time-of-day, resolve back to UTC) — "every day at 8am" stays 8am across a DST transition.
  A fall-back overlap resolves to the earlier instant; a spring-forward gap lands just after it.
  """
  @spec next_occurrence(DateTime.t(), map() | nil, String.t()) :: DateTime.t() | nil
  def next_occurrence(due_at, rule, tz)

  def next_occurrence(_due_at, nil, _tz), do: nil

  def next_occurrence(%DateTime{} = due_at, rule, tz) when is_map(rule) do
    remaining = rule["remaining"] || rule["count"]

    if is_integer(remaining) and remaining <= 1 do
      nil
    else
      local = DateTime.shift_zone!(due_at, tz)

      interval =
        if is_integer(rule["interval"]) and rule["interval"] >= 1, do: rule["interval"], else: 1

      with %Date{} = date <- next_date(rule["freq"], DateTime.to_date(local), interval, rule),
           %DateTime{} = next <- resolve_local(date, DateTime.to_time(local), tz),
           :ok <- check_until(next, rule["until"]) do
        next
      else
        _ -> nil
      end
    end
  end

  defp next_date("daily", date, interval, _rule), do: Date.add(date, interval)

  # Weekly: the next listed weekday strictly after `date` within the same ISO (Mon-start) week;
  # when the week rolls, jump to the FIRST listed day of the week `interval` weeks later —
  # multi-day byday fires each listed day, stepping `interval` weeks between full cycles.
  defp next_date("weekly", date, interval, rule) do
    dows =
      case rule["byday"] do
        [_ | _] = codes ->
          codes
          |> Enum.map(&@day_codes[&1])
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.sort()

        _ ->
          []
      end

    dows = if dows == [], do: [Date.day_of_week(date)], else: dows
    cur = Date.day_of_week(date)

    case Enum.find(dows, &(&1 > cur)) do
      nil ->
        monday = Date.add(date, -(cur - 1))
        Date.add(monday, interval * 7 + (hd(dows) - 1))

      dow ->
        Date.add(date, dow - cur)
    end
  end

  # Monthly: same day-of-month `interval` months on, clamped to the target month's last valid
  # day. When the current date IS its month's last day we anchor to "end of month" (31) — that
  # keeps the clamp chain Jan 31 -> Feb 28 -> Mar 31 without storing the original anchor
  # (accepted v1 trade-off: "every 30th" created on Apr 30 rides month-ends).
  defp next_date("monthly", date, interval, _rule) do
    months = date.year * 12 + (date.month - 1) + interval
    year = div(months, 12)
    month = rem(months, 12) + 1
    anchor = if date.day == Date.days_in_month(date), do: 31, else: date.day
    Date.new!(year, month, min(anchor, Date.days_in_month(Date.new!(year, month, 1))))
  end

  # Yearly: same month + day `interval` years on; Feb-29 clamps to Feb 28 in a non-leap year.
  defp next_date("yearly", date, interval, _rule) do
    year = date.year + interval
    Date.new!(year, date.month, min(date.day, Date.days_in_month(Date.new!(year, date.month, 1))))
  end

  defp next_date(_freq, _date, _interval, _rule), do: nil

  # Resolve a LOCAL wall-clock date+time back to a UTC instant. Ambiguous (fall-back overlap):
  # keep the earlier instant. Gap (spring-forward): the wall time doesn't exist — land just
  # after the gap.
  defp resolve_local(%Date{} = date, %Time{} = time, tz) do
    case DateTime.from_naive(NaiveDateTime.new!(date, time), tz) do
      {:ok, dt} -> to_utc(dt)
      {:ambiguous, first, _second} -> to_utc(first)
      {:gap, _just_before, just_after} -> to_utc(just_after)
      {:error, _} -> nil
    end
  end

  defp to_utc(dt), do: dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

  defp check_until(_next, nil), do: :ok

  defp check_until(next, until) when is_binary(until) do
    case DateTime.from_iso8601(until) do
      {:ok, u, _} -> if DateTime.compare(next, u) == :gt, do: :exhausted, else: :ok
      # unparseable until (shouldn't survive Task 6's normalize) → treat as open-ended
      _ -> :ok
    end
  end

  defp check_until(_next, _until), do: :ok

  @doc """
  Advance a RECURRING reminder to its next occurrence (called by the scheduler after
  fire + deliver). nil recurrence → :noop (a one-shot is untouched — the additive invariant).

  Fast-forwards past any occurrences that were missed ENTIRELY during downtime (the app was
  down longer than the recurrence interval — e.g. a daily reminder while the kiosk was off for
  days): repeatedly steps `next_occurrence` until it lands strictly after `now`, so a stale
  reminder delivers ONCE (the overdue occurrence the scheduler already fired this tick) and then
  resumes on its normal future schedule — no catch-up storm of one delivery per scheduler tick.
  When the very next occurrence is already in the future (the common case — no downtime), this
  is exactly today's single-step behavior.

  Series exhausted, or fast-forwarding runs the series past `until` → {:ok, :complete}: the row
  stays fired and drops out of the schedule naturally. Otherwise the SAME row is reset — due_at
  = the first future occurrence, fired/delivered/acknowledged cleared, remaining decremented
  ONCE (skipped occurrences were never delivered, so they never consume count/remaining) — and
  {:reminders_changed} is broadcast. Idempotent: next is recomputed from the struct's own
  due_at, so replaying an advance on the same fired struct converges on the same row state
  (the crash-between-fire-and-advance story).

  `now` is injectable for deterministic tests; defaults to the real clock.
  """
  def advance(reminder, now \\ DateTime.utc_now())

  def advance(%Reminder{recurrence: nil}, _now), do: :noop

  def advance(%Reminder{} = r, %DateTime{} = now) do
    case catch_up(r.due_at, r.recurrence, App.Config.timezone(), now) do
      nil ->
        {:ok, :complete}

      %DateTime{} = next ->
        case r
             |> Reminder.changeset(%{
               due_at: next,
               fired_at: nil,
               delivered_at: nil,
               acknowledged_at: nil,
               recurrence: decrement_remaining(r.recurrence)
             })
             |> Repo.update() do
          {:ok, updated} ->
            broadcast_changed(updated.user_id, updated.household)
            {:ok, updated}

          other ->
            other
        end
    end
  end

  # Step `next_occurrence` forward from `due_at`, skipping any occurrence that is still `<= now`
  # (missed entirely during downtime), until the first one strictly after `now` — or nil if the
  # series completes/exhausts along the way (next_occurrence returns nil: past `until`, or count
  # exhausted). The rule is threaded through UNCHANGED at every hop — skipped occurrences were
  # never delivered, so they must not consume count/remaining; only the caller's single
  # post-catch-up `decrement_remaining` does. Defensively terminates if a hop ever failed to move
  # time forward (next_occurrence always strictly advances in practice, but this keeps the loop
  # provably finite rather than relying on that).
  defp catch_up(due_at, rule, tz, now) do
    case next_occurrence(due_at, rule, tz) do
      nil ->
        nil

      %DateTime{} = next ->
        cond do
          DateTime.compare(next, now) == :gt -> next
          DateTime.compare(next, due_at) != :gt -> next
          true -> catch_up(next, rule, tz, now)
        end
    end
  end

  defp decrement_remaining(%{"count" => c} = rule) when is_integer(c) do
    Map.update(rule, "remaining", c - 1, fn
      n when is_integer(n) -> n - 1
      _ -> c - 1
    end)
  end

  defp decrement_remaining(rule), do: rule

  @doc """
  The user's best-matching ACTIVE reminder for a spoken phrase — scheduled (not yet fired) OR
  recurring (any state, so a series is findable even mid-delivery), own OR household. Same
  containment matching as `find_pending/2`; soonest due wins ties. Backs cancel_reminder
  ("stop reminding me about the bins") and the recurring-ack read-back. nil when nothing matches.
  """
  def find_active(user_id, phrase) when is_binary(phrase) do
    p = phrase |> String.downcase() |> String.trim()

    if p == "" do
      nil
    else
      Reminder
      |> where(
        [r],
        (r.user_id == ^user_id or r.household == true) and
          (is_nil(r.fired_at) or not is_nil(r.recurrence))
      )
      |> Repo.all()
      |> Enum.filter(fn r ->
        b = String.downcase(r.body)
        String.contains?(b, p) or String.contains?(p, b)
      end)
      |> Enum.sort_by(& &1.due_at, {:asc, DateTime})
      |> List.first()
    end
  end

  def find_active(_user_id, _phrase), do: nil

  @doc "Upcoming household (shared) reminders only — backs the Shared-scope view."
  def list_household_upcoming do
    now = now()

    Reminder
    |> where([r], r.household == true and is_nil(r.fired_at) and r.due_at >= ^now)
    |> order_by([r], asc: r.due_at, asc: r.id)
    |> Repo.all()
  end

  @doc "Unfired reminders whose time has come (across all users — the scheduler routes by user)."
  def due_now(at \\ nil) do
    cutoff = at || now()

    Reminder
    |> where([r], is_nil(r.fired_at) and r.due_at <= ^cutoff)
    |> Repo.all()
  end

  def mark_fired(%Reminder{} = r) do
    r |> Reminder.changeset(%{fired_at: now()}) |> Repo.update()
  end

  @doc "Tell subscribers the reminder set changed. Household rows also notify every member's panel."
  def broadcast_changed(user_id) do
    Phoenix.PubSub.broadcast(App.PubSub, "reminders:#{user_id}", {:reminders_changed})
  end

  def broadcast_changed(user_id, true) do
    broadcast_changed(user_id)
    Phoenix.PubSub.broadcast(App.PubSub, "reminders:household", {:reminders_changed})
  end

  def broadcast_changed(user_id, false), do: broadcast_changed(user_id)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
