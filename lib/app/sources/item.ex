defmodule App.Sources.Item do
  @moduledoc "One indexed external item (email/calendar event): dedup + change-detection tracking."
  use Ecto.Schema
  import Ecto.Changeset

  schema "source_items" do
    field :user_id, :id
    field :account_id, :id
    field :source, :string
    field :external_id, :string
    field :content_hash, :string
    field :at, :utc_datetime
    field :indexed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime)
  end

  @fields [:user_id, :account_id, :source, :external_id, :content_hash, :at, :indexed_at]

  def changeset(item, attrs) do
    item
    |> cast(attrs, @fields)
    |> validate_required([:user_id, :account_id, :source, :external_id, :content_hash])
    |> unique_constraint([:user_id, :source, :account_id, :external_id])
  end
end
