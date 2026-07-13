defmodule App.Speaker.GateEvent do
  @moduledoc "One gate decision (audit list + shadow calibration). Pruned to newest 100/user."
  use Ecto.Schema

  schema "voice_gate_events" do
    field :user_id, :integer
    field :decision, :string
    field :reason, :string
    field :score, :float
    field :speech_ms, :integer
    field :transcript, :string
    field :mode, :string
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
