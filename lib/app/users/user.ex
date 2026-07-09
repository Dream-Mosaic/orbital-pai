defmodule App.Users.User do
  @moduledoc "A person who uses the app. Identity only; connections live elsewhere."
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :name, :string
    field :default_abi, :boolean, default: false
    field :default_ptt, :boolean, default: false
    field :voice_activation, :boolean, default: false
    field :relock_seconds, :integer, default: 15
    timestamps(type: :utc_datetime)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name])
    |> validate_required([:email, :name])
    |> unique_constraint(:email)
  end

  @doc false
  def prefs_changeset(user, attrs) do
    cast(user, attrs, [:default_abi, :default_ptt, :voice_activation, :relock_seconds])
  end
end
