defmodule App.Memory.ProfileFact do
  @moduledoc "A durable, editable fact about the user. source: \"auto\" (model) | \"user\" (curated)."
  use Ecto.Schema
  import Ecto.Changeset

  schema "profile_facts" do
    field :category, :string
    field :content, :string
    field :source, :string, default: "auto"
    field :user_id, :id
    timestamps(type: :utc_datetime)
  end

  def changeset(fact, attrs) do
    fact
    |> cast(attrs, [:category, :content, :source, :user_id])
    |> validate_required([:content, :user_id])
    |> validate_inclusion(:source, ["auto", "user"])
  end
end
