defmodule App.Garden.Plant do
  @moduledoc """
  One garden plant — personal or household. Only `name` is required ("the tomatoes I planted
  in the back" is a complete, valid plant); species/location/count/planted_on are filled only
  when the user mentions them. Lifecycle: `status` "active" | "archived" — archiving stamps
  `season` (defaulting to the year of `archived_at`) + `archived_at` and keeps the row as
  history. UNLIKE lists, same-named plants may legitimately coexist across seasons (this
  year's tomatoes + last year's archived ones) — history, not a collision.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active archived)

  schema "plants" do
    field :user_id, :id
    field :household, :boolean, default: false
    field :name, :string
    field :species, :string
    field :location, :string
    field :count, :integer
    field :planted_on, :date
    field :status, :string, default: "active"
    field :season, :string
    field :archived_at, :utc_datetime
    has_many :notes, App.Garden.Note
    timestamps(type: :utc_datetime)
  end

  @fields [
    :user_id,
    :household,
    :name,
    :species,
    :location,
    :count,
    :planted_on,
    :status,
    :season,
    :archived_at
  ]

  def changeset(plant, attrs) do
    plant
    |> cast(attrs, @fields)
    |> validate_required([:user_id, :name])
    |> validate_inclusion(:status, @statuses)
  end
end
