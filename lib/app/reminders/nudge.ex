defmodule App.Reminders.Nudge do
  @moduledoc """
  Pull-on-connect re-surfacing: when a session starts and the user has PENDING (fired, un-acked)
  reminders, build ONE consolidated agenda item where Henry checks in and asks the user to confirm.
  Reminders that fire *during* the session deliver normally — this only sees what's pending at
  connect time, so a just-delivered one is never immediately re-asked. `ack: nil` (the human acks
  via the acknowledge_reminder tool, not on delivery). Mirrors App.Agenda.Briefing.pull/1.
  """
  alias App.Agenda.Item
  alias App.Reminders

  # Cap the check-in so a chronic pile stays one short turn (nag-tuning is a later knob).
  @max 5

  @spec pull(String.t()) :: Item.t() | nil
  def pull(session_id) do
    case App.Users.id_from_session(session_id) do
      nil -> nil
      user_id -> item_for(Reminders.list_unacknowledged(user_id))
    end
  end

  defp item_for([]), do: nil

  defp item_for(pending) do
    list =
      pending
      |> Enum.take(@max)
      |> Enum.map(&~s|"#{&1.body}"|)
      |> Enum.join(", ")

    %Item{
      kind: :reminder,
      prompt:
        "The user has reminder(s) that fired earlier but haven't been confirmed yet: #{list}. " <>
          "Warmly and briefly check in — did they get to it/them? When they confirm one, call " <>
          "acknowledge_reminder with its task phrase. One short check-in, not one turn per reminder; " <>
          "don't lecture.",
      lead_idle: "Quick one —",
      lead_interjected: "Oh — one thing —",
      deliver: :when_idle,
      ack: nil
    }
  end
end
