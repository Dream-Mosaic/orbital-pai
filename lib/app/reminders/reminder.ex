defmodule App.Reminders.Reminder do
  @moduledoc "A one-shot reminder: fire `body` at `due_at`; `fired_at` stamps delivery (the dedupe guard)."
  use Ecto.Schema
  import Ecto.Changeset

  schema "reminders" do
    field :user_id, :id
    field :body, :string
    field :due_at, :utc_datetime
    field :fired_at, :utc_datetime
    field :acknowledged_at, :utc_datetime
    # "reminder" (default) or "followup" (an open loop Henry offered to check back on);
    # context = a one-line note of the original commitment, used to phrase the question.
    field :kind, :string, default: "reminder"
    field :context, :string
    timestamps(type: :utc_datetime)
  end

  @fields [:user_id, :body, :due_at, :fired_at, :acknowledged_at, :kind, :context]

  def changeset(reminder, attrs) do
    reminder
    |> cast(attrs, @fields)
    |> validate_required([:body, :due_at, :user_id])
    |> validate_inclusion(:kind, ["reminder", "followup"])
  end
end
