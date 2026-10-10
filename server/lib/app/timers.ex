defmodule App.Timers do
  @moduledoc """
  Kitchen timers: named, several at once, per user. Persistence + state transitions, plus the
  notify seam: every state change broadcasts `{:timers_changed, user_id}` on `"timers:<user_id>"`,
  which every one of the user's `VoiceChannel`s subscribes to (each device re-pushes `wire/1`).

  Lifecycle (`App.Timers.Timer`): `running` → `ringing` (`fire/1`, by `App.Timers.Scheduler`) →
  `done` (`dismiss/2`, or `settle_ringing/1` when nobody does). `cancel/2` ends a running timer
  as `cancelled` and silences a ringing one as `done` — "stop the timer" means the same thing
  whether it has gone off yet or not.

  Every transition is a CONDITIONAL update (`WHERE state = <from>`), so a fire racing a cancel
  resolves to exactly one winner and `fire/1` is idempotent: a cancelled timer can never ring.
  """
  import Ecto.Query

  alias App.Agenda.Item
  alias App.Repo
  alias App.Timers.Timer

  @max_seconds 86_400
  @active ~w(running ringing)
  # A fired timer's spoken notice is pointless once it is this stale (the device was away).
  @notice_ttl_s 600

  @doc """
  Start a timer of `seconds` (1 s .. 24 h). `label` is trimmed and stored as said; a blank one is
  no label. Arms the scheduler and broadcasts. `{:error, :invalid_duration}` out of range.
  """
  def create(user_id, seconds, label \\ nil)

  def create(user_id, seconds, label)
      when is_integer(seconds) and seconds >= 1 and seconds <= @max_seconds do
    now = now()

    attrs = %{
      user_id: user_id,
      label: clean_label(label),
      duration_ms: seconds * 1000,
      ends_at: DateTime.add(now, seconds * 1000, :millisecond),
      state: "running"
    }

    case %Timer{} |> Timer.changeset(attrs) |> Repo.insert() do
      {:ok, timer} ->
        App.Timers.Scheduler.schedule(timer)
        broadcast(timer.user_id)
        {:ok, timer}

      other ->
        other
    end
  end

  def create(_user_id, _seconds, _label), do: {:error, :invalid_duration}

  @doc "The user's running + ringing timers: ringing ones first, then soonest to ring."
  def list_active(user_id) do
    Timer
    |> where([t], t.user_id == ^user_id and t.state in ^@active)
    |> order_by([t],
      asc: fragment("CASE WHEN ? = 'ringing' THEN 0 ELSE 1 END", t.state),
      asc: t.ends_at,
      asc: t.id
    )
    |> Repo.all()
  end

  @doc "Every running timer, across users — the scheduler's boot reload."
  def list_running, do: list_in_state("running")

  @doc "Every ringing timer, across users — the scheduler re-arms their auto-settle on boot."
  def list_ringing, do: list_in_state("ringing")

  defp list_in_state(state) do
    Timer |> where([t], t.state == ^state) |> order_by([t], asc: t.ends_at) |> Repo.all()
  end

  @doc """
  Stop the user's timer(s): `:all`, an id, or a spoken label. Running → `cancelled`, ringing →
  `done`. `{:ok, [stopped]}`; `{:error, :not_found}` when nothing matches;
  `{:error, {:ambiguous, matches}}` when a label matches several (an exact label match wins over
  a partial one, so "pasta" picks "pasta" over "pasta sauce"). Only ever the user's own timers.
  """
  def cancel(user_id, :all) do
    case list_active(user_id) do
      [] -> {:error, :not_found}
      timers -> stop_all(user_id, timers)
    end
  end

  def cancel(user_id, id) when is_integer(id) do
    case Enum.find(list_active(user_id), &(&1.id == id)) do
      nil -> {:error, :not_found}
      timer -> stop_all(user_id, [timer])
    end
  end

  def cancel(user_id, label) when is_binary(label) do
    key = match_key(label)
    active = list_active(user_id)

    matches =
      case Enum.filter(active, &(match_key(&1.label) == key)) do
        [] -> Enum.filter(active, &partial_match?(&1.label, key))
        exact -> exact
      end

    case matches do
      [] -> {:error, :not_found}
      [timer] -> stop_all(user_id, [timer])
      many -> {:error, {:ambiguous, many}}
    end
  end

  defp stop_all(user_id, timers) do
    stopped = for t <- timers, {:ok, s} <- [stop_one(t)], do: s

    case stopped do
      [] ->
        {:error, :not_found}

      _ ->
        broadcast(user_id)
        {:ok, stopped}
    end
  end

  defp stop_state("ringing"), do: "done"
  defp stop_state("running"), do: "cancelled"

  # The state we read can be a beat stale: "cancel the pasta timer" said just as it fires reads
  # `running`, but the scheduler's fire lands first and the running→cancelled update matches no
  # row. Retry once from `ringing` so the user's stop still stops it.
  @doc false
  def stop_one(%Timer{state: "running"} = t) do
    case transition(t.id, "running", "cancelled") do
      {:ok, _} = ok -> ok
      _ -> transition(t.id, "ringing", "done")
    end
  end

  def stop_one(%Timer{state: state} = t), do: transition(t.id, state, stop_state(state))

  @doc """
  An active timer of the user's with this label and duration started in the last `window_s`
  seconds, or nil — so a second tap on the same cook-mode pill (another device, a rebuilt card)
  returns the first timer instead of starting a twin.
  """
  def recent_twin(user_id, seconds, label, window_s \\ 120) when is_integer(user_id) do
    since = DateTime.add(DateTime.utc_now(), -window_s, :second)
    ms = seconds * 1000

    user_id
    |> list_active()
    |> Enum.find(fn t ->
      t.duration_ms == ms and t.label == label and DateTime.compare(t.inserted_at, since) == :gt
    end)
  end

  @doc """
  Add `seconds` to one of the user's timers: by spoken label, or `nil` for the obvious one (the
  ringing one, else the only one). A RUNNING timer's end moves out (and its total grows, so the
  strip's progress stays honest); a RINGING one is snoozed — running again, ending `seconds`
  from now ("give it five more minutes"). `{:ok, timer}`, `{:error, :not_found}`,
  `{:error, {:ambiguous, timers}}` or `{:error, :invalid_duration}`.
  """
  def extend(user_id, target, seconds)
      when is_integer(seconds) and seconds >= 1 and seconds <= @max_seconds do
    with {:ok, timer} <- pick(user_id, target) do
      now = now()

      changes =
        case timer.state do
          "ringing" ->
            [
              state: "running",
              ends_at: DateTime.add(now, seconds, :second),
              duration_ms: seconds * 1000,
              fired_at: nil
            ]

          "running" ->
            [
              ends_at: DateTime.add(timer.ends_at, seconds, :second),
              duration_ms: timer.duration_ms + seconds * 1000
            ]
        end

      {count, _} =
        Timer
        |> where([t], t.id == ^timer.id and t.state == ^timer.state)
        |> Repo.update_all(set: changes ++ [updated_at: now])

      if count == 1 do
        extended = Repo.get!(Timer, timer.id)
        # A RUNNING timer still has its original fire pending: the scheduler re-checks the end
        # when it arrives and re-arms for the new one. Arming here too would leave TWO fires at
        # the new end. A snoozed (was ringing) timer has no fire pending, so it needs one.
        if timer.state == "ringing", do: App.Timers.Scheduler.schedule(extended)
        broadcast(user_id)
        {:ok, extended}
      else
        # it changed state under us (rang, or was dismissed) — let the caller try again
        {:error, :not_found}
      end
    end
  end

  def extend(_user_id, _target, _seconds), do: {:error, :invalid_duration}

  defp pick(user_id, label) when is_binary(label) and label != "" do
    key = match_key(label)
    active = list_active(user_id)

    case Enum.filter(active, &(match_key(&1.label) == key)) do
      [] -> Enum.filter(active, &partial_match?(&1.label, key))
      exact -> exact
    end
    |> one()
  end

  defp pick(user_id, _none) do
    active = list_active(user_id)

    case Enum.filter(active, &(&1.state == "ringing")) do
      [ringing] -> {:ok, ringing}
      _ -> one(active)
    end
  end

  defp one([]), do: {:error, :not_found}
  defp one([t]), do: {:ok, t}
  defp one(many), do: {:error, {:ambiguous, many}}

  @doc "Is any of the user's timers ringing right now? (a read — cheap enough for the FSM)"
  def any_ringing?(user_id) when is_integer(user_id) do
    Timer |> where([t], t.user_id == ^user_id and t.state == "ringing") |> Repo.exists?()
  end

  @doc """
  Silence every RINGING timer of the user (→ done) — "Henry, stop" / "okay" while the alarm
  sounds. Returns how many were silenced (0 = nothing was ringing).
  """
  def silence_ringing(user_id) when is_integer(user_id) do
    Timer
    |> where([t], t.user_id == ^user_id and t.state == "ringing")
    |> Repo.all()
    |> Enum.count(fn t -> match?({:ok, _}, dismiss(user_id, t.id)) end)
  end

  @doc "Is this timer still ringing? The guard a queued 'timer's done' notice re-checks."
  def ringing?(id), do: match?(%Timer{state: "ringing"}, Repo.get(Timer, id))

  @doc "Silence one of the user's RINGING timers (→ done). `{:error, :not_found}` otherwise."
  def dismiss(user_id, id) when is_integer(id) do
    with %Timer{} <- Repo.get_by(Timer, id: id, user_id: user_id, state: "ringing"),
         {:ok, timer} <- transition(id, "ringing", "done") do
      broadcast(user_id)
      {:ok, timer}
    else
      _ -> {:error, :not_found}
    end
  end

  def dismiss(_user_id, _id), do: {:error, :not_found}

  @doc "It went off: running → ringing, stamping `fired_at`. `:noop` unless it was running."
  def fire(id) do
    id
    |> transition("running", "ringing", fired_at: now())
    |> tap_broadcast()
  end

  @doc "Nobody dismissed it: ringing → done. `:noop` unless it was ringing."
  def settle_ringing(id), do: id |> transition("ringing", "done") |> tap_broadcast()

  @doc "It came due while the server was down too long ago to ring now: running → done, quietly."
  def expire_missed(id), do: id |> transition("running", "done") |> tap_broadcast()

  defp tap_broadcast({:ok, timer} = ok) do
    broadcast(timer.user_id)
    ok
  end

  defp tap_broadcast(:noop), do: :noop

  defp transition(id, from, to, extra \\ []) do
    {count, _} =
      Timer
      |> where([t], t.id == ^id and t.state == ^from)
      |> Repo.update_all(set: [state: to, updated_at: now()] ++ extra)

    if count == 1, do: {:ok, Repo.get!(Timer, id)}, else: :noop
  end

  @doc """
  The client payload: one map per active timer, `remaining_ms` computed NOW (never negative;
  0 once ringing) so each device anchors the countdown to its own clock — no clock skew.
  """
  def wire(user_id) do
    now = now()

    user_id
    |> list_active()
    |> Enum.map(fn t ->
      %{
        id: t.id,
        label: t.label,
        state: t.state,
        duration_ms: t.duration_ms,
        remaining_ms: remaining_ms(t, now)
      }
    end)
  end

  @doc "Milliseconds left on a timer at `now` (0 once ringing or overdue)."
  def remaining_ms(%Timer{state: "running", ends_at: ends_at}, now),
    do: max(0, DateTime.diff(ends_at, now, :millisecond))

  def remaining_ms(%Timer{}, _now), do: 0

  @doc """
  The spoken notice for a timer that just went off: a CANNED agenda item (spoken verbatim, no
  model call) — "Your pasta timer is up." / "Your 10-minute timer is up." Not persisted as a
  conversation turn; dropped if it can't be spoken within #{div(@notice_ttl_s, 60)} minutes.
  """
  def agenda_item(%Timer{} = timer) do
    %Item{
      kind: :timer,
      canned: true,
      prompt: spoken_notice(timer),
      lead_idle: "Timer's done —",
      lead_interjected: "Oh — your timer —",
      deliver: :when_idle,
      expires_at: DateTime.add(DateTime.utc_now(), @notice_ttl_s, :second),
      # queued behind a turn and dismissed meanwhile (tap or "stop the timer") → don't announce it
      still_due: {__MODULE__, :ringing?, [timer.id]}
    }
  end

  defp spoken_notice(%Timer{label: label}) when is_binary(label) and label != "" do
    if String.match?(String.downcase(label), ~r/\btimer$/u),
      do: "Your #{label} is up.",
      else: "Your #{label} timer is up."
  end

  defp spoken_notice(%Timer{duration_ms: ms}), do: "Your #{duration_phrase(ms)} timer is up."

  # "10-minute" for a single unit, "1 hour 30 minute" for a mix — both read naturally aloud.
  defp duration_phrase(ms) do
    s = div(ms, 1000)

    [{div(s, 3600), "hour"}, {div(rem(s, 3600), 60), "minute"}, {rem(s, 60), "second"}]
    |> Enum.reject(fn {n, _} -> n == 0 end)
    |> case do
      [] -> "short"
      [{n, unit}] -> "#{n}-#{unit}"
      parts -> Enum.map_join(parts, " ", fn {n, unit} -> "#{n} #{unit}" end)
    end
  end

  # How a label is compared: case-insensitive, and "the pasta timer" == "pasta".
  defp match_key(nil), do: ""

  defp match_key(label) do
    label
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/^(the|my|our)\s+/u, "")
    |> String.replace(~r/\s*\btimers?$/u, "")
    |> String.trim()
  end

  defp partial_match?(label, key) do
    lk = match_key(label)
    lk != "" and (String.contains?(lk, key) or String.contains?(key, lk))
  end

  defp clean_label(label) when is_binary(label) do
    case String.trim(label) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean_label(_), do: nil

  defp broadcast(user_id) do
    Phoenix.PubSub.broadcast(App.PubSub, "timers:#{user_id}", {:timers_changed, user_id})
  end

  defp now, do: DateTime.utc_now()
end
