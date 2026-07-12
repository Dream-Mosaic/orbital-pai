defmodule App.Reminders.Scheduler do
  @moduledoc """
  Ticks every 15s, finds reminders whose time has come, stamps them fired, and broadcasts
  `{:reminder_due, reminder}` on `"reminders:<user_id>"`. DB-driven (no in-memory timers),
  so a restart just resumes and the `fired_at` stamp guarantees exactly-once delivery.
  """
  use GenServer
  require Logger

  alias App.Reminders

  @interval_ms 15_000

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

  @doc "Fire all due reminders now. Public so tests can drive it without waiting 15s."
  def tick do
    for r <- Reminders.due_now() do
      case Reminders.mark_fired(r) do
        {:ok, fired} ->
          Logger.info(
            "[reminders] firing ##{fired.id} #{inspect(fired.body)} " <>
              "(household=#{fired.household}) → reminders:#{fired.user_id}"
          )

          Phoenix.PubSub.broadcast(
            App.PubSub,
            "reminders:#{fired.user_id}",
            {:reminder_due, fired}
          )

          if fired.household do
            # visual backstop: refresh EVERY member's panel (both LiveViews watch this topic)
            Phoenix.PubSub.broadcast(App.PubSub, "reminders:household", {:reminders_changed})
            # spoken: wall-USER-first (the user logged into the kiosk), else any active member
            case App.Reminders.Delivery.target(AppWeb.Presence.list("presence:voice")) do
              nil -> :ok
              target_uid -> App.Agenda.deliver(target_uid, App.Agenda.reminder_item(fired))
            end
          else
            App.Agenda.deliver(fired.user_id, App.Agenda.reminder_item(fired))
          end

          maybe_advance(fired)

        {:error, reason} ->
          Logger.warning("[reminders] mark_fired failed: #{inspect(reason)}")
      end
    end

    :ok
  rescue
    e ->
      Logger.error("[reminders] tick crashed: #{inspect(e)}")
      :ok
  end

  # Recurrence: after the current occurrence is fired + handed to delivery, the SAME row
  # advances to its next due_at (fired/delivered/acknowledged reset) — it re-enters the
  # schedule and never lingers as "pending", so it never joins the nudge loop. A one-shot
  # (nil recurrence) is untouched: the guard keeps today's path byte-for-byte identical.
  # Series complete (next == nil) leaves the row fired — the FINAL occurrence keeps the
  # one-shot ack lifecycle from here on. Advancing runs for personal AND household rows,
  # even when a household row found no present listener (the series advances on cadence).
  defp maybe_advance(%App.Reminders.Reminder{recurrence: nil}), do: :ok

  defp maybe_advance(fired) do
    case Reminders.advance(fired) do
      {:ok, :complete} ->
        Logger.info("[reminders] recurring ##{fired.id} series complete")

      {:ok, %App.Reminders.Reminder{} = next} ->
        Logger.info("[reminders] recurring ##{fired.id} advanced → next due #{next.due_at}")

      other ->
        Logger.warning("[reminders] advance failed for ##{fired.id}: #{inspect(other)}")
    end
  end

  defp schedule, do: Process.send_after(self(), :tick, @interval_ms)
end
