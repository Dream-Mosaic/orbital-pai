defmodule App.Timers.Timer do
  @moduledoc """
  A countdown timer: rings at `ends_at`. `state` is the whole lifecycle —
  `running` (counting down) → `ringing` (went off, `fired_at` stamped) → `done` (dismissed, or
  auto-settled a few minutes after ringing); `cancelled` ends a running one early. `label` is
  kept exactly as said ("Pasta"); matching against it is case-insensitive (see `App.Timers`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(running ringing done cancelled)

  schema "timers" do
    field :user_id, :id
    field :label, :string
    field :duration_ms, :integer
    field :ends_at, :utc_datetime_usec
    field :state, :string, default: "running"
    field :fired_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(timer, attrs) do
    timer
    |> cast(attrs, [:user_id, :label, :duration_ms, :ends_at, :state, :fired_at])
    |> validate_required([:user_id, :duration_ms, :ends_at, :state])
    |> validate_number(:duration_ms, greater_than: 0)
    |> validate_inclusion(:state, @states)
  end
end
