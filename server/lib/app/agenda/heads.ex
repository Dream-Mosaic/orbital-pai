defmodule App.Agenda.Heads do
  @moduledoc """
  Calendar heads-ups: "Heads up — Poke the Brain starts in 10 minutes."

  Every `poll_ms` (5 min), for each user who has the `heads_up` pref on AND is around to hear it
  right now (a live Conversation with a connected voice device — `App.Messages.recipient_live?/1`;
  nobody listening means no Google API calls spent on them), read their timed events in
  `[now, now + 40 min]` through the SAME calendar tool the brain calls (shared cache, timeouts,
  sequential token refresh — the users are polled one after another, never concurrently, so two
  users' refreshes can't contend for SQLite's single writer). Each upcoming event gets a
  `Process.send_after` at `start - 10 min`, or right away when it's already inside that window.

  Dedup: the armed set is keyed `{user_id, start (unix), title}`, so re-polls never re-arm and
  the same invite on two connected accounts nudges once. Keys are pruned once their event is
  past its expiry.

  At fire time the nudge is re-checked, because 10 minutes is long enough for things to change:
  the pref must still be on, the device still connected (a heads-up spoken to an empty room is
  noise), and the event still on the calendar (one more fetch, so a cancelled or moved meeting is
  not announced). A dropped nudge frees its key, so a later poll can still nudge inside the
  window if the user comes back. A calendar error at fire time delivers anyway — the event was
  there minutes ago.

  Delivery is a CANNED agenda item (`kind: :heads_up`, spoken verbatim, no model call),
  `:when_idle` like a fired reminder — explicit, time-bound intent, so it does not wait for the
  wake word the way the morning briefing does. Not persisted as a turn. Expires 2 minutes after
  the event starts. All-day events never nudge. Declined events cannot be told apart yet:
  `App.Google.Calendar` normalizes attendees to bare emails and drops `responseStatus`.

  Gated by `:start_heads_up` (off in test; tests `start_supervised!/1` it with `poll_ms: nil`
  and drive `poll/1`). Options: `:name`, `:poll_ms`, `:now` (clock fun), `:config`,
  `:listening?` (uid -> boolean).
  """
  use GenServer
  require Logger

  import Ecto.Query

  alias App.Agenda
  alias App.Agenda.Item
  alias App.Repo
  alias App.Users
  alias App.Users.User

  @poll_ms 5 * 60_000
  # The first poll comes sooner than a full interval: devices reconnect within seconds of a boot.
  @first_poll_ms 60_000
  @lead_s 10 * 60
  @horizon_s 40 * 60
  # A heads-up is still worth saying shortly after the start ("starts now"), not later.
  @expires_after_s 2 * 60
  # Within this of the start, the phrase is "starts now" rather than "in 0 minutes".
  @now_window_s 30

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Poll now (synchronously). Tests drive the producer with this; safe to call in prod."
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, 60_000)

  @impl true
  def init(opts) do
    state = %{
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0),
      config: Keyword.get(opts, :config),
      listening?: Keyword.get(opts, :listening?, &App.Messages.recipient_live?/1),
      armed: %{}
    }

    if state.poll_ms, do: Process.send_after(self(), :tick, min(@first_poll_ms, state.poll_ms))
    {:ok, state}
  end

  @impl true
  def handle_call(:poll, _from, state), do: {:reply, :ok, guarded_poll(state)}

  @impl true
  def handle_info(:tick, state) do
    state = guarded_poll(state)
    Process.send_after(self(), :tick, state.poll_ms)
    {:noreply, state}
  end

  def handle_info({:nudge, key, nudge}, state) do
    keep? =
      try do
        fire(key, nudge, state)
      rescue
        e ->
          Logger.error("[heads-up] nudge crashed: #{Exception.message(e)}")
          false
      end

    {:noreply, if(keep?, do: state, else: %{state | armed: Map.delete(state.armed, key)})}
  end

  # ---- poll ----

  # A DB or calendar hiccup must not crash-loop the producer; the next poll retries. Guarded PER
  # USER as well, so one user's failure can't throw away the keys another user's nudges were just
  # armed under (which would re-arm them, and speak them twice, on the next poll).
  defp guarded_poll(state) do
    now = state.now.()
    armed = prune(state.armed, now)

    armed = Enum.reduce(heads_up_users(), armed, &guarded_arm(&1.id, now, &2, state))
    %{state | armed: armed}
  rescue
    e ->
      Logger.error("[heads-up] poll crashed: #{Exception.message(e)}")
      state
  end

  # Nobody listening → skip the user entirely: no Google API calls for a room no one is in.
  defp guarded_arm(uid, now, armed, state) do
    if state.listening?.(uid), do: arm_user(uid, now, armed, state), else: armed
  rescue
    e ->
      Logger.error("[heads-up] user #{uid}: poll crashed: #{Exception.message(e)}")
      armed
  end

  defp heads_up_users, do: Repo.all(from u in User, where: u.heads_up == true)

  defp arm_user(uid, now, armed, state) do
    case fetch_events(uid, now, state) do
      {:ok, events} ->
        events
        |> plan(now)
        |> Enum.reduce(armed, fn nudge, acc ->
          key = key(uid, nudge)

          if Map.has_key?(acc, key) do
            acc
          else
            delay = max(0, DateTime.diff(nudge.fire_at, now, :millisecond))
            Logger.info("[heads-up] user #{uid}: #{inspect(nudge.title)} armed in #{delay}ms")
            Process.send_after(self(), {:nudge, key, nudge}, delay)
            Map.put(acc, key, nudge.start)
          end
        end)

      :error ->
        armed
    end
  end

  @doc false
  # The nudges for `events` as of `now` (pure): timed events that haven't started, each with the
  # moment to speak — `start - lead`, or `now` when that's already passed.
  def plan(events, now) do
    for %{start: start} = event <- timed(events), DateTime.compare(start, now) == :gt do
      lead_line = DateTime.add(start, -@lead_s, :second)

      Map.put(
        event,
        :fire_at,
        if(DateTime.compare(lead_line, now) == :gt, do: lead_line, else: now)
      )
    end
  end

  # Every TIMED event (all-day ones never nudge), started or not, as `%{start, title, location}`.
  defp timed(events) do
    for %{} = event <- events,
        event[:all_day?] != true,
        {:ok, start} <- [parse_start(event[:start])],
        do: %{start: start, title: event[:summary], location: event[:location]}
  end

  defp parse_start(start) when is_binary(start) do
    case DateTime.from_iso8601(start) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_start(_), do: :error

  defp key(uid, %{start: start, title: title}), do: {uid, DateTime.to_unix(start), title}

  defp prune(armed, now) do
    cutoff = DateTime.add(now, -@expires_after_s, :second)
    Map.reject(armed, fn {_key, start} -> DateTime.compare(start, cutoff) == :lt end)
  end

  # ---- fire ----

  # true = delivered (keep the key so no re-poll nudges again); false = dropped (free the key).
  defp fire({uid, _start, _title} = key, nudge, state) do
    now = state.now.()

    cond do
      not pref_on?(uid) ->
        Logger.info("[heads-up] user #{uid}: pref off since arming, dropped")
        false

      not state.listening?.(uid) ->
        Logger.info(
          "[heads-up] user #{uid}: no device listening, dropped #{inspect(nudge.title)}"
        )

        false

      true ->
        case still_on_calendar(uid, key, nudge, now, state) do
          {:ok, current} ->
            Logger.info("[heads-up] user #{uid}: #{inspect(nudge.title)} → agenda:#{uid}")
            Agenda.deliver(uid, item(%{nudge | location: current.location}, now))
            true

          :gone ->
            Logger.info("[heads-up] user #{uid}: #{inspect(nudge.title)} gone, dropped")
            false
        end
    end
  end

  defp pref_on?(uid), do: match?(%User{heads_up: true}, Users.get(uid))

  # Re-read the calendar: the matching event (for its current location), :gone, or — when the
  # calendar can't be read — the armed nudge itself (benefit of the doubt).
  defp still_on_calendar(uid, key, nudge, now, state) do
    case fetch_events(uid, now, state) do
      {:ok, events} ->
        # Started or not: at fire time the start may be seconds away, or just past.
        case Enum.find(timed(events), &(key(uid, &1) == key)) do
          nil -> :gone
          current -> {:ok, current}
        end

      :error ->
        {:ok, nudge}
    end
  end

  defp fetch_events(uid, now, state) do
    ctx = %{
      session_id: to_string(uid),
      user_id: uid,
      config: state.config || App.Config.default()
    }

    args = %{
      "time_min" => DateTime.to_iso8601(now),
      "time_max" => DateTime.to_iso8601(DateTime.add(now, @horizon_s, :second))
    }

    case App.Tools.execute("get_calendar_events", args, ctx) do
      {:ok, %{events: events}} when is_list(events) ->
        {:ok, events}

      other ->
        Logger.debug("[heads-up] user #{uid}: no calendar read: #{inspect(other)}")
        :error
    end
  end

  # ---- the spoken item ----

  @doc "The canned agenda item for `nudge` (`%{start, title, location}`), worded as of `now`."
  def item(%{start: start} = nudge, now) do
    %Item{
      kind: :heads_up,
      canned: true,
      deliver: :when_idle,
      prompt: prompt(nudge.title, nudge.location, start, now),
      lead_idle: "Heads up —",
      lead_interjected: "Oh — quick heads up —",
      persist_as: nil,
      expires_at: DateTime.add(start, @expires_after_s, :second)
    }
  end

  @doc """
  The spoken line (pure): "Poke the Brain starts in 10 minutes, at 1086 Cromwell Ln." Minutes
  are counted from `now` to the real start, so a nudge that fired late still says the truth.
  """
  def prompt(title, location, %DateTime{} = start, %DateTime{} = now) do
    "#{subject(title)} #{when_phrase(DateTime.diff(start, now, :second))}#{where(location)}."
  end

  defp subject(title) when is_binary(title) do
    case String.trim(title) do
      "" -> "Your next event"
      "(no title)" -> "Your next event"
      t -> t
    end
  end

  defp subject(_), do: "Your next event"

  defp when_phrase(secs) when secs <= @now_window_s, do: "starts now"

  defp when_phrase(secs) do
    case max(1, round(secs / 60)) do
      1 -> "starts in 1 minute"
      n -> "starts in #{n} minutes"
    end
  end

  # Short form: the text before the first comma ("1086 Cromwell Ln, Belleville, IL" → "1086
  # Cromwell Ln"). A meeting link is not a place anyone wants read aloud, so URL-ish values
  # (a scheme, or one unbroken token with a dot or slash) are left out.
  defp where(location) when is_binary(location) do
    short = location |> String.split(",", parts: 2) |> hd() |> String.trim()

    cond do
      short == "" -> ""
      url_like?(short) -> ""
      true -> ", at #{short}"
    end
  end

  defp where(_), do: ""

  defp url_like?(s),
    do:
      String.contains?(s, "://") or
        (not String.contains?(s, " ") and String.contains?(s, ["/", "."]))
end
