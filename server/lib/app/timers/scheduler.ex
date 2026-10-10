defmodule App.Timers.Scheduler do
  @moduledoc """
  Rings timers on time. Unlike the reminder scheduler's 15 s DB tick (minute-grained work), a
  timer is second-grained, so each running timer gets its own `Process.send_after` — armed by
  `schedule/1` when `App.Timers.create/3` inserts it, and re-armed from the DB on boot.

  On fire: `App.Timers.fire/1` (running → ringing, broadcast to every device's strip) and a
  CANNED agenda item to the user's Conversation ("Your pasta timer is up."), then a settle
  timer: a ringing timer nobody dismisses goes to `done` after `ring_ms` (5 min).

  The DB is the truth, not the arms: a fire message re-checks state (`fire/1` is a conditional
  update), so a cancelled timer's stale arm is a harmless no-op — nothing needs disarming.

  Boot catch-up: a running timer that came due while the server was down rings late if it is
  less than `catchup_ms` (15 min) overdue; older ones go to `done` silently (a pasta alarm an
  hour late is noise, not help). Ringing timers get their settle re-armed.

  Off in test (`start_timer_scheduler: false`); tests `start_supervised!/1` it (opts
  `ring_ms` / `catchup_ms` shrink the windows). With it absent, `schedule/1` is a no-op cast.
  """
  use GenServer
  require Logger

  alias App.Timers
  alias App.Timers.Timer

  @ring_ms 5 * 60_000
  @catchup_ms 15 * 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Arm a freshly created timer. A no-op when the scheduler isn't running (test env)."
  def schedule(%Timer{id: id, ends_at: ends_at}) do
    GenServer.cast(__MODULE__, {:schedule, id, ends_at})
  end

  @impl true
  def init(opts) do
    state = %{
      ring_ms: Keyword.get(opts, :ring_ms, @ring_ms),
      catchup_ms: Keyword.get(opts, :catchup_ms, @catchup_ms)
    }

    {:ok, state, {:continue, :reload}}
  end

  @impl true
  def handle_continue(:reload, state) do
    guarded("reload", fn -> reload(state) end)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:schedule, id, ends_at}, state) do
    arm(id, ends_at)
    {:noreply, state}
  end

  @impl true
  def handle_info({:fire, id}, state) do
    guarded("fire ##{id}", fn -> ring(id, state) end)
    {:noreply, state}
  end

  def handle_info({:settle, id}, state) do
    guarded("settle ##{id}", fn -> Timers.settle_ringing(id) end)
    {:noreply, state}
  end

  defp reload(state) do
    now = DateTime.utc_now()

    for t <- Timers.list_running() do
      overdue = DateTime.diff(now, t.ends_at, :millisecond)

      cond do
        overdue <= 0 ->
          arm(t.id, t.ends_at)

        overdue < state.catchup_ms ->
          Logger.info("[timers] ##{t.id} came due #{div(overdue, 1000)}s ago — ringing late")
          send(self(), {:fire, t.id})

        true ->
          Logger.info("[timers] ##{t.id} came due #{div(overdue, 60_000)}m ago — marking done")
          Timers.expire_missed(t.id)
      end
    end

    for t <- Timers.list_ringing() do
      rung_for = DateTime.diff(now, t.fired_at || t.ends_at, :millisecond)
      Process.send_after(self(), {:settle, t.id}, max(0, state.ring_ms - rung_for))
    end

    :ok
  end

  defp arm(id, ends_at) do
    delay = max(0, DateTime.diff(ends_at, DateTime.utc_now(), :millisecond))
    Process.send_after(self(), {:fire, id}, delay)
  end

  defp ring(id, state) do
    case Timers.fire(id) do
      {:ok, timer} ->
        Logger.info("[timers] ##{id} ringing → agenda:#{timer.user_id}")
        App.Agenda.deliver(timer.user_id, Timers.agenda_item(timer))
        Process.send_after(self(), {:settle, id}, state.ring_ms)

      :noop ->
        :ok
    end
  end

  # A DB hiccup must not crash-loop the scheduler (a restart storm takes the app supervisor
  # down with it); the next boot reload re-arms anything a failure dropped.
  defp guarded(what, fun) do
    fun.()
  rescue
    e -> Logger.error("[timers] #{what} crashed: #{Exception.message(e)}")
  end
end
