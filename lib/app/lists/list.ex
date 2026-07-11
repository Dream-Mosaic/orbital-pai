defmodule App.Lists.List do
  @moduledoc """
  A named list of check-off items — personal or household. A "book" when named (Groceries,
  Plants); the generic default is "To-do". Identified by (owner scope, name) — one household
  "Groceries", not five.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "lists" do
    field :user_id, :id
    field :household, :boolean, default: false
    field :name, :string
    has_many :items, App.Lists.Item
    timestamps(type: :utc_datetime)
  end

  @fields [:user_id, :household, :name]

  def changeset(list, attrs) do
    list
    |> cast(attrs, @fields)
    |> validate_required([:user_id, :name])
  end
end
