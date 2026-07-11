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

  @doc "A fired follow-up as an agenda item: Henry ASKS about the open loop; the exchange persists."
  def reminder_item(%Reminder{kind: "followup"} = r) do
    context_sentence = if r.context, do: ~s| Context: "#{r.context}".|, else: ""

    %Item{
      kind: :followup,
      prompt:
        ~s|A follow-up you set earlier is due. You'd agreed to check back on: "#{r.body}".| <>
          context_sentence <>
          " Ask the user about it naturally and briefly — did it get resolved? " <>
          "Don't lecture and don't use tools unless they ask you to.",
      lead_idle: "By the way —",
      lead_interjected: "Oh — while I think of it —",
      persist_as: "(follow-up: #{r.body})",
      ack: {App.Reminders, :mark_delivered, [r]},
      reminder_id: r.id
    }
  end

  # A fired HOUSEHOLD (shared) reminder — phrase it as shared so whoever's listening isn't told
  # they set it, and the brain relays it as a household reminder.
  def reminder_item(%Reminder{household: true} = r) do
    %Item{
      kind: :reminder,
      prompt:
        "A shared household reminder just came due: \"#{r.body}\". It's for the household, not " <>
          "necessarily whoever's listening — relay it briefly as a shared reminder. If it's " <>
          "something you can do with your tools, do it and say what it was; otherwise just remind us." <>
          " Then wait for a \"got it\" from someone — don't mark it done yourself.",
      lead_idle: "Heads up, for the house —",
      lead_interjected: "Oh — a shared reminder —",
      ack: {App.Reminders, :mark_delivered, [r]},
      reminder_id: r.id
    }
  end

  # A fired reminder as an agenda item (text identical to the old App.Reminders.Notice).
  def reminder_item(%Reminder{} = r) do
    %Item{
      kind: :reminder,
      prompt:
        "A reminder you set earlier just came due: \"#{r.body}\". Carry it out now — if it's " <>
          "something you can do with your tools, do it and briefly tell me what it was and the " <>
          "result. If it's not something you can do, just remind me of it, briefly." <>
          " Then wait for me to tell you I've got it (a quick \"got it\" is enough) — " <>
          "don't mark it done yourself.",
      lead_idle: "Heads up —",
      lead_interjected: "Oh, before I forget —",
      ack: {App.Reminders, :mark_delivered, [r]},
      reminder_id: r.id
    }
  end

  @doc "Is this item past its expiry? (nil = never expires)"
  def expired?(%Item{expires_at: nil}), do: false
  def expired?(%Item{expires_at: at}), do: DateTime.compare(DateTime.utc_now(), at) == :gt
end
