defmodule App.Memory.Digest do
  @moduledoc "One ~100-word archived summary of one user's day (episodic memory substrate)."
  use Ecto.Schema
  import Ecto.Changeset

  schema "daily_digests" do
    field :user_id, :id
    field :date, :date
    field :content, :string
    field :embedded_at, :utc_datetime_usec
    timestamps(type: :utc_datetime)
  end

  def changeset(digest, attrs) do
    digest
    |> cast(attrs, [:user_id, :date, :content])
    |> validate_required([:user_id, :date, :content])
    |> unique_constraint([:user_id, :date])
  end
end
