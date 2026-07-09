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
    timestamps(type: :utc_datetime)
  end

  @fields [:user_id, :body, :due_at, :fired_at, :acknowledged_at]

  def changeset(reminder, attrs) do
    reminder
    |> cast(attrs, @fields)
    |> validate_required([:body, :due_at, :user_id])
  end
end
