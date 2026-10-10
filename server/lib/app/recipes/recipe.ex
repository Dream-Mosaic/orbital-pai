defmodule App.Recipes.Recipe do
  @moduledoc """
  One saved recipe — household-shared by default (like lists), or private to `user_id` when
  `household` is false. `name` is the normalized match key (`App.Recipes.normalize/1`) and is
  unique per owner scope (one household "lasagna"; one personal "lasagna" per user — see the
  migration); `title` is the name as the user said it, for read-back. `ingredients` and
  `steps` are ordered lists of plain strings (steps are stored un-numbered; the tool numbers
  them on the way out).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "recipes" do
    field :user_id, :id
    field :household, :boolean, default: true
    field :name, :string
    field :title, :string
    field :ingredients, {:array, :string}, default: []
    field :steps, {:array, :string}, default: []
    field :servings, :string
    field :notes, :string
    field :source, :string
    timestamps(type: :utc_datetime)
  end

  @fields [:user_id, :household, :name, :title, :ingredients, :steps, :servings, :notes, :source]

  def changeset(recipe, attrs) do
    recipe
    |> cast(attrs, @fields)
    |> validate_required([:user_id, :name, :title])
    |> validate_length(:name, max: 120)
    |> validate_length(:title, max: 120)
    |> validate_length(:servings, max: 60)
    |> validate_length(:source, max: 500)
    |> validate_length(:notes, max: 4_000)
    |> validate_length(:ingredients, max: 100)
    |> validate_length(:steps, max: 60)
    |> unique_constraint(:name, name: :recipes_name_index)
    |> unique_constraint(:name, name: :recipes_user_id_name_index)
  end
end
