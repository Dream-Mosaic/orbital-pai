defmodule App.Memory.Summary do
  @moduledoc "Singleton rolling summary of the user + conversation (model-maintained, user-editable)."
  use Ecto.Schema
  import Ecto.Changeset

  schema "summary" do
    field :content, :string, default: ""
    field :user_id, :id
    timestamps(type: :utc_datetime)
  end

  def changeset(summary, attrs) do
    summary |> cast(attrs, [:content, :user_id]) |> validate_required([:user_id])
  end
end
