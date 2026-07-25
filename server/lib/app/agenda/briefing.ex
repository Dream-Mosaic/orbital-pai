defmodule App.Agenda.Briefing do
  @moduledoc """
  Morning-briefing producer. A briefing is DUE for a user while their local wall-clock is within
  [briefing_time, briefing_time + 5h) and today isn't yet delivered (briefing_last_on != today).
  Two triggers deliver it, both via `due_item/2`:
    * this 60s GenServer tick broadcasts it to a connected session (the always-on kiosk);
    * the Conversation calls `pull/1` on start and self-injects it (a phone opened after the time).
  The claim (stamping `briefing_last_on`) happens at DELIVERY via the item's `ack`, so nothing is
  ever claimed-but-lost. The brain assembles the content live from its tools at delivery time.
  Spec: docs/superpowers/specs/2026-07-03-morning-briefing-design.md
  """
  use GenServer
  require Logger

  alias App.Agenda
  alias App.Agenda.Item
  alias App.Users
  alias App.Users.User

  @interval_ms 60_000
  @ttl_hours 5

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    tick()
    schedule()
    {:noreply, state}
  end

  @doc "Broadcast every due user's briefing. Public so tests can drive it without waiting a minute."
  def tick do
    local_now = DateTime.now!(App.Config.timezone())

    for user <- Users.list_briefing_users(),
        item = due_item(user, local_now),
        not is_nil(item) do
      Logger.info("[briefing] due for user #{user.id} → agenda:#{user.id}")
      Agenda.deliver(user.id, item)
    end

    :ok
  rescue
    e ->
      Logger.error("[briefing] tick crashed: #{inspect(e)}")
      :ok
  end

  @doc """
  The due briefing item for the session's user right now, or nil. Called by the Conversation on
  start (pull-on-connect). Guards non-user sessions and missing users.
  """
  def pull(session_id) do
    with id when is_integer(id) <- Users.id_from_session(session_id),
         %User{} = user <- Users.get(id) do
      due_item(user, DateTime.now!(App.Config.timezone()))
    else
      _ -> nil
    end
  end

  @doc "The briefing `%Item{}` if the user is due at `local_now`, else nil (pure)."
  def due_item(%User{briefing_time: t} = user, local_now) when is_binary(t) do
    today = DateTime.to_date(local_now)

    case ready_at(local_now, t) do
      {:ok, ready_at} ->
        window_end = DateTime.add(ready_at, @ttl_hours * 3600, :second)
        started? = DateTime.compare(local_now, ready_at) != :lt
        within? = DateTime.compare(local_now, window_end) == :lt
        fresh? = user.briefing_last_on != today

        if started? and within? and fresh?, do: item(user, today), else: nil

      :error ->
        nil
    end
  end

  def due_item(_user, _local_now), do: nil

  @doc "The briefing agenda item: first-interaction delivery, 5h shelf life, claim-at-delivery."
  def item(%User{} = user, %Date{} = local_date) do
    %Item{
      kind: :briefing,
      deliver: :after_next_turn,
      recent_context: false,
      persist_as: "(morning briefing)",
      lead_idle: "Morning —",
      lead_interjected: "Oh — and here's your morning rundown.",
      ack: {Users, :stamp_briefing!, [user, local_date]},
      expires_at: DateTime.add(DateTime.utc_now(), @ttl_hours * 3600, :second),
      prompt:
        "It's the user's morning briefing. Assemble it now with your tools: today's weather " <>
          "(lead with anything that changes plans — rain, heat, wind), today's calendar events " <>
          "across their connected accounts (times in their local timezone), and any reminders " <>
          "due today. Keep it tight and spoken — a few sentences, no lists, no markdown. Lead " <>
          "with the most time-sensitive thing. If a tool fails, skip it without apologizing " <>
          "at length."
    }
  end

  # Today's briefing_time as a zoned DateTime in local_now's zone; :error on a DST gap/ambiguity.
  defp ready_at(local_now, hhmm) do
    with [h, m] <- String.split(hhmm, ":"),
         {:ok, time} <- Time.new(String.to_integer(h), String.to_integer(m), 0),
         {:ok, dt} <- DateTime.new(DateTime.to_date(local_now), time, local_now.time_zone) do
      {:ok, dt}
    else
      _ -> :error
    end
  end

  defp schedule, do: Process.send_after(self(), :tick, @interval_ms)
end
