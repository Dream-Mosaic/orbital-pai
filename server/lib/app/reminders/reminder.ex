defmodule App.Reminders.Reminder do
  @moduledoc """
  A reminder: fire `body` at `due_at`; `fired_at` stamps delivery (the dedupe guard).
  `recurrence` nil = one-shot (unchanged legacy behavior). Present = the repeat rule
  (string-keyed, JSON in SQLite): %{"freq" => "daily"|"weekly"|"monthly"|"yearly",
  "interval" => n, "byday" => ["tue"], "until" => iso8601 | nil, "count" => n | nil,
  "remaining" => n | nil}. The rule is read only when advancing (never in a WHERE clause);
  it is validated at the tool seam, so the changeset casts it permissively.
  """
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
    field :household, :boolean, default: false
    field :delivered_at, :utc_datetime
    field :recurrence, :map
    timestamps(type: :utc_datetime)
  end

  @fields [
    :user_id,
    :body,
    :due_at,
    :fired_at,
    :acknowledged_at,
    :kind,
    :context,
    :household,
    :delivered_at,
    :recurrence
  ]

  def changeset(reminder, attrs) do
    reminder
    |> cast(attrs, @fields)
    |> validate_required([:body, :due_at, :user_id])
    |> validate_inclusion(:kind, ["reminder", "followup"])
  end
end
