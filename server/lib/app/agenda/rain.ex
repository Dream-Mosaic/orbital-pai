defmodule App.Agenda.Rain do
  @moduledoc """
  Rain heads-ups: "Heads up — Rain's starting in about 20 minutes."

  Every `poll_ms` (10 min), and ONLY when at least one user has the `heads_up` pref on AND a
  connected voice device (`App.Messages.recipient_live?/1` — nobody listening means no forecast
  fetched), read Open-Meteo's 15-minute precipitation for home (`App.Config :weather_home`): the
  last 2 hours plus the next ~2. The same people and the same switch as calendar heads-ups
  (`App.Agenda.Heads`).

  The decision is one pure function, `decide/4`, over normalized slots (`%{at, mm, prob}`, `at`
  being the START of the 15-minute interval). A slot is wet at ≥ 0.1 mm or a precipitation
  probability ≥ 60%. Rain "starts" at the first wet slot after a DRY current slot; when that is
  15–45 minutes away, every eligible user is told once. One alert per rain event: wetness seen
  (any started wet slot, including the forecast's recent past, so a polling gap can't hide a
  shower) or an alerted start keeps the alert disarmed until 2 hours have passed dry. At most 3
  alerts per local day, none between 22:00 and 07:00 local (`App.Config.timezone/0`).

  The decision state is the home's, not a user's: one forecast, one event. A user who connects
  after the alert has missed it.

  Delivery is a CANNED agenda item (`kind: :heads_up`, verbatim, no model call), `:when_idle`
  like a calendar heads-up, expiring when the rain is due. Not persisted.

  Gated by `:start_rain_alerts` (off in test; tests `start_supervised!/1` it with `poll_ms: nil`
  and drive `poll/1`). Options: `:name`, `:poll_ms`, `:now` (clock fun), `:tz`, `:config`,
  `:fetch` (`{lat, lon, label} -> {:ok, slots} | {:error, reason}`), `:listening?` (uid -> bool).
  """
  use GenServer
  require Logger

  import Ecto.Query

  alias App.Agenda
  alias App.Agenda.Item
  alias App.Repo
  alias App.Users.User

  @poll_ms 10 * 60_000
  # The first poll comes sooner than a full interval: devices reconnect within seconds of a boot.
  @first_poll_ms 60_000

  @forecast_url "https://api.open-meteo.com/v1/forecast"
  @slot_s 15 * 60
  # 8 past slots = the 2 hours the re-arm rule looks back over; 8 ahead covers the 45-min window.
  @past_slots 8
  @ahead_slots 8

  @wet_mm 0.1
  @wet_prob 60
  @window_min_s 15 * 60
  @window_max_s 45 * 60
  @rearm_s 2 * 60 * 60
  @daily_cap 3
  # Local hours: quiet from 22:00 up to 07:00.
  @quiet_from 22
  @quiet_until 7

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
      tz: Keyword.get(opts, :tz),
      config: Keyword.get(opts, :config),
      fetch: Keyword.get(opts, :fetch, &fetch/1),
      listening?: Keyword.get(opts, :listening?, &App.Messages.recipient_live?/1),
      decision: initial_state()
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

  # ---- poll ----

  # A DB or forecast hiccup must not crash-loop the producer; the next poll retries.
  defp guarded_poll(state) do
    case listeners(state) do
      [] -> state
      uids -> check(uids, state)
    end
  rescue
    e ->
      Logger.error("[rain] poll crashed: #{Exception.message(e)}")
      state
  end

  # Heads-up users with a device connected right now. Guarded per user, so one user's presence
  # check failing can't cost the others their heads-up.
  defp listeners(state) do
    for %User{id: uid} <- Repo.all(from u in User, where: u.heads_up == true),
        listening?(uid, state),
        do: uid
  end

  defp listening?(uid, state) do
    state.listening?.(uid) == true
  rescue
    e ->
      Logger.error("[rain] user #{uid}: presence check crashed: #{Exception.message(e)}")
      false
  end

  defp check(uids, state) do
    now = state.now.()
    config = state.config || App.Config.default()

    case state.fetch.(config.weather_home) do
      {:ok, slots} ->
        case decide(slots, now, state.decision, state.tz || App.Config.timezone()) do
          {:alert, minutes, decision} ->
            Logger.info("[rain] rain in ~#{minutes} min → #{length(uids)} user(s)")
            item = item(minutes, decision.rain_at)
            Enum.each(uids, &Agenda.deliver(&1, item))
            %{state | decision: decision}

          {:quiet, decision} ->
            %{state | decision: decision}
        end

      {:error, reason} ->
        Logger.warning("[rain] forecast fetch failed: #{inspect(reason)}")
        state
    end
  end

  # ---- the decision (pure) ----

  @doc """
  The decision state before any forecast: `last_wet_at` (the end of the latest wet slot seen),
  `rain_at` (the predicted start of the last event alerted), `alerts` (today's alert times).
  """
  def initial_state, do: %{last_wet_at: nil, rain_at: nil, alerts: []}

  @doc """
  Should Henry say rain is coming? `slots` are `%{at, mm, prob}` (`at` = interval start), `now`
  is UTC, `tz` places quiet hours and the day for the cap. Returns `{:alert, minutes, state}`
  (minutes to the start, rounded to 5; `state.rain_at` is that start) or `{:quiet, state}`.
  Either way the returned state carries what this forecast showed, so pass it to the next call.
  """
  def decide(slots, %DateTime{} = now, state, tz \\ App.Config.timezone()) do
    slots = Enum.sort_by(slots, & &1.at, DateTime)
    local = DateTime.shift_zone!(now, tz)
    state = state |> observe(slots, now) |> todays_alerts(local, tz)

    with %{} = current <- Enum.find(slots, &covers?(&1, now)),
         false <- wet?(current),
         %{at: start} <- first_wet_after(slots, current),
         lead_s = DateTime.diff(start, now, :second),
         true <- lead_s in @window_min_s..@window_max_s,
         true <- armed?(state, now),
         false <- quiet_hours?(local),
         true <- length(state.alerts) < @daily_cap do
      {:alert, round(lead_s / 300) * 5, %{state | rain_at: start, alerts: [now | state.alerts]}}
    else
      _ -> {:quiet, state}
    end
  end

  # Every wet slot that has started (the current one included) is wetness seen, through its end.
  defp observe(state, slots, now) do
    slots
    |> Enum.filter(&(wet?(&1) and DateTime.compare(&1.at, now) != :gt))
    |> Enum.map(&DateTime.add(&1.at, @slot_s, :second))
    |> Enum.reduce(state, fn ended, acc ->
      %{acc | last_wet_at: latest(acc.last_wet_at, ended)}
    end)
  end

  defp todays_alerts(state, local, tz) do
    today = DateTime.to_date(local)

    %{
      state
      | alerts:
          Enum.filter(state.alerts, &(DateTime.to_date(DateTime.shift_zone!(&1, tz)) == today))
    }
  end

  defp covers?(%{at: at}, now) do
    DateTime.compare(at, now) != :gt and
      DateTime.compare(now, DateTime.add(at, @slot_s, :second)) == :lt
  end

  defp first_wet_after(slots, %{at: current}) do
    Enum.find(slots, &(DateTime.compare(&1.at, current) == :gt and wet?(&1)))
  end

  defp wet?(slot) do
    (is_number(slot[:mm]) and slot[:mm] >= @wet_mm) or
      (is_number(slot[:prob]) and slot[:prob] >= @wet_prob)
  end

  # Armed when nothing wet has been seen or announced in the last 2 hours.
  defp armed?(state, now) do
    case latest(state.last_wet_at, state.rain_at) do
      nil -> true
      last -> DateTime.diff(now, last, :second) >= @rearm_s
    end
  end

  defp quiet_hours?(%DateTime{hour: h}), do: h >= @quiet_from or h < @quiet_until

  defp latest(nil, b), do: b
  defp latest(a, nil), do: a
  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  # ---- the forecast ----

  @doc """
  Open-Meteo's 15-minute precipitation for `{lat, lon, label}` as slots, `{:ok, slots}` or
  `{:error, reason}`. Stubbed in tests through `:weather_req_opts`, like the weather tool.
  `precipitation_probability` isn't in Open-Meteo's documented 15-minute list, but the endpoint
  serves it (interpolated from hourly); `slots/1` reads it as nil if that ever stops.
  """
  def fetch({lat, lon, _label}) do
    opts =
      [
        params: [
          latitude: lat,
          longitude: lon,
          minutely_15: "precipitation,precipitation_probability",
          past_minutely_15: @past_slots,
          forecast_minutely_15: @ahead_slots,
          timeformat: "unixtime"
        ],
        finch: App.Finch,
        receive_timeout: 5_000
      ] ++ Application.get_env(:app, :weather_req_opts, [])

    case Req.get(@forecast_url, opts) do
      {:ok, %{status: 200, body: body}} ->
        case slots(body) do
          [] -> {:error, :no_data}
          slots -> {:ok, slots}
        end

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Normalizes an Open-Meteo `minutely_15` body (unixtime labels) to slots (pure). Each value is
  the sum over the PRECEDING 15 minutes, so a slot starts 15 minutes before its label.
  """
  def slots(%{"minutely_15" => %{"time" => times} = series}) when is_list(times) do
    mm = Map.get(series, "precipitation") || []
    prob = Map.get(series, "precipitation_probability") || []

    for {label, i} <- Enum.with_index(times), is_integer(label) do
      %{
        at: DateTime.from_unix!(label - @slot_s),
        mm: Enum.at(mm, i),
        prob: Enum.at(prob, i)
      }
    end
  end

  def slots(_), do: []

  # ---- the spoken item ----

  @doc "The canned agenda item: rain in about `minutes`, worth saying until it's due at `rain_at`."
  def item(minutes, %DateTime{} = rain_at) do
    %Item{
      kind: :heads_up,
      canned: true,
      deliver: :when_idle,
      prompt: "Rain's starting in about #{minutes} minutes.",
      lead_idle: "Heads up —",
      lead_interjected: "Oh — quick heads up —",
      persist_as: nil,
      expires_at: rain_at
    }
  end
end
