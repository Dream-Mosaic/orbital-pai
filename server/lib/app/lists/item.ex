defmodule App.Lists.Item do
  @moduledoc "One check-off item on a list. `checked_at` nil = unchecked; set = done (strikethrough)."
  use Ecto.Schema
  import Ecto.Changeset

  schema "list_items" do
    field :text, :string
    field :checked_at, :utc_datetime
    belongs_to :list, App.Lists.List
    timestamps(type: :utc_datetime)
  end

  @fields [:list_id, :text, :checked_at]

  def changeset(item, attrs) do
    item
    |> cast(attrs, @fields)
    |> validate_required([:list_id, :text])
  end
end
