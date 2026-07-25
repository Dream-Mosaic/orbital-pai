defmodule App.Speaker.Enrollment do
  @moduledoc "One enrolled voice clip: raw PCM (kept for model swaps) + its embedding."
  use Ecto.Schema

  schema "voice_enrollments" do
    field :user_id, :integer
    field :slot, :integer
    field :audio, :binary
    field :embedding, :binary
    field :model_id, :string
    timestamps(type: :utc_datetime)
  end
end
