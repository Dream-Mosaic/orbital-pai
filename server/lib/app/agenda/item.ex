defmodule App.Agenda.Item do
  @moduledoc """
  A self-initiated spoken turn, as plain data. Producers (reminder scheduler, briefing,
  follow-ups) compute everything at enqueue time; the Conversation FSM just executes it.
  Spec: docs/superpowers/specs/2026-07-03-agenda-framework-design.md
  """

  @enforce_keys [:kind, :prompt]
  defstruct kind: nil,
            # the brain instruction for the self-initiated turn
            prompt: nil,
            # canned reflex-slot lead per delivery mode
            lead_idle: "Heads up —",
            lead_interjected: "Oh, before I forget —",
            # :when_idle — speak now if listening, else queue (reminders today);
            # :after_next_turn — never self-starts; interjects after a user turn completes
            deliver: :when_idle,
            # include recent conversation turns in the brain context?
            recent_context: false,
            # nil = don't persist the turn; a string = persist it with this user_text
            persist_as: nil,
            # drop (never speak) if delivery would happen after this moment
            expires_at: nil,
            # {m, f, a} run async when the turn starts (e.g. reminder acknowledge)
            ack: nil,
            # the source reminder's id, when this item delivers a persisted reminder — lets the
            # client offer an inline "Ack" chip that acknowledges exactly this reminder. nil = no chip.
            reminder_id: nil

  @type t :: %__MODULE__{}
end
