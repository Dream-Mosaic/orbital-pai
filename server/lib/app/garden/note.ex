defmodule App.Garden.Note do
  @moduledoc "One check-in note on a plant. `noted_on` nil = undated; the log orders by inserted_at."
  use Ecto.Schema
  import Ecto.Changeset

  schema "plant_notes" do
    field :body, :string
    field :noted_on, :date
    belongs_to :plant, App.Garden.Plant
    timestamps(type: :utc_datetime)
  end

  @fields [:plant_id, :body, :noted_on]

  def changeset(note, attrs) do
    note
    |> cast(attrs, @fields)
    |> validate_required([:plant_id, :body])
  end
end
