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

  defp schedule, do: Process.send_after(self(), :tick, @interval_ms)
end
