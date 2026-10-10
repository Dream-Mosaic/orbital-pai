defmodule App.Routines.Routine do
  @moduledoc """
  One routine: a named, natural-language macro the brain carries out with its own tools
  ("when I say good night, turn off the downstairs lights and set the thermostat to 68").
  Per-user. `name` is the match key (`App.Routines.match_key/1`) and is unique per user —
  saving a routine under an existing name replaces it; `label` is the name as the user said
  it. `triggers` are extra phrases that run it (the name always does). `steps` is free text,
  written as imperative instructions to the brain.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_steps 2_000
  @max_label 80

  schema "routines" do
    field :user_id, :id
    field :name, :string
    field :label, :string
    field :triggers, {:array, :string}, default: []
    field :steps, :string
    field :last_run_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def max_steps, do: @max_steps

  def changeset(routine, attrs) do
    routine
    |> cast(attrs, [:user_id, :name, :label, :triggers, :steps, :last_run_at])
    |> validate_required([:user_id, :name, :label, :steps])
    |> validate_length(:label, max: @max_label)
    |> validate_length(:steps, max: @max_steps)
    |> unique_constraint([:user_id, :name])
  end
end
