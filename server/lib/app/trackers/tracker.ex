defmodule App.Trackers.Tracker do
  @moduledoc """
  One thing a user tracks over time (headaches, weight, sleep hours, "no soda"). Per-user and
  private — never shared, never visible to another user. Created implicitly by the first logged
  entry. `name` is the normalized match key (`App.Trackers.normalize/1`: "My Headaches" →
  "headache") and is unique per user; `label` is the name as the user first said it, for
  read-back. `unit` is optional and free-form ("pain 1–10", "lb", "hours").
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "trackers" do
    field :user_id, :id
    field :name, :string
    field :label, :string
    field :unit, :string
    has_many :entries, App.Trackers.Entry
    timestamps(type: :utc_datetime)
  end

  @fields [:user_id, :name, :label, :unit]

  def changeset(tracker, attrs) do
    tracker
    |> cast(attrs, @fields)
    |> validate_required([:user_id, :name, :label])
    |> validate_length(:name, max: 80)
    |> validate_length(:label, max: 80)
    |> validate_length(:unit, max: 40)
    |> unique_constraint([:user_id, :name])
  end
end
