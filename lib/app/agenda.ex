defmodule App.Agenda do
  @moduledoc """
  Delivery seam for self-initiated turns: producers `deliver/2` an `App.Agenda.Item` on the
  per-user `"agenda:<user_id>"` topic; the user's Conversation subscribes and speaks it
  (idle-now / queued / interjected — see the FSM). UI concerns stay on the separate
  `"reminders:<user_id>"` topic.
  """

  alias App.Agenda.Item
  alias App.Reminders.Reminder

  @doc "Broadcast an agenda item to the user's Conversation."
  def deliver(user_id, %Item{} = item) do
    Phoenix.PubSub.broadcast(App.PubSub, "agenda:#{user_id}", {:agenda_due, item})
  end

  @doc "A fired reminder as an agenda item (text identical to the old App.Reminders.Notice)."
  def reminder_item(%Reminder{} = r) do
    %Item{
      kind: :reminder,
      prompt:
        "A reminder you set earlier just came due: \"#{r.body}\". Carry it out now — if it's " <>
          "something you can do with your tools, do it and briefly tell me what it was and the " <>
          "result. If it's not something you can do, just remind me of it, briefly.",
      lead_idle: "Heads up —",
      lead_interjected: "Oh, before I forget —",
      ack: {App.Reminders, :acknowledge, [r]}
    }
  end

  @doc "Is this item past its expiry? (nil = never expires)"
  def expired?(%Item{expires_at: nil}), do: false
  def expired?(%Item{expires_at: at}), do: DateTime.compare(DateTime.utc_now(), at) == :gt
end
