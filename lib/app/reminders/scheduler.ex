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
            "[reminders] firing ##{fired.id} #{inspect(fired.body)} → reminders:#{fired.user_id}"
          )

          Phoenix.PubSub.broadcast(
            App.PubSub,
            "reminders:#{fired.user_id}",
            {:reminder_due, fired}
          )

          # spoken delivery rides the agenda framework; the broadcast above stays UI-only
          App.Agenda.deliver(fired.user_id, App.Agenda.reminder_item(fired))

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
