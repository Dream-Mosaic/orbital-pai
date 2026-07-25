defmodule App.Memory.Turn do
  @moduledoc "One completed turn: the conversation log + the spike's per-turn metrics."
  use Ecto.Schema
  import Ecto.Changeset

  schema "turns" do
    field :user_id, :id
    field :user_text, :string
    field :reflex_text, :string
    field :brain_text, :string
    field :reflex_ms, :integer
    field :brain_ms, :integer
    field :ttfa_ms, :integer
    field :ttb_ms, :integer
    field :embedded_at, :utc_datetime_usec
    timestamps(type: :utc_datetime)
  end

  @fields [
    :user_id,
    :user_text,
    :reflex_text,
    :brain_text,
    :reflex_ms,
    :brain_ms,
    :ttfa_ms,
    :ttb_ms
  ]

  def changeset(turn, attrs) do
    turn |> cast(attrs, @fields) |> validate_required([:user_id])
  end
end
