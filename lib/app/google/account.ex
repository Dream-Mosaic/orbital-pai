defmodule App.Google.Account do
  @moduledoc "A connected Google account: identity (email/label) + OAuth tokens."
  use Ecto.Schema
  import Ecto.Changeset

  schema "google_accounts" do
    field :user_id, :id
    field :email, :string
    field :label, :string
    field :refresh_token, :string
    field :access_token, :string
    field :access_token_expires_at, :utc_datetime
    field :scope, :string
    field :is_default, :boolean, default: false
    timestamps(type: :utc_datetime)
  end

  @fields [
    :user_id,
    :email,
    :label,
    :refresh_token,
    :access_token,
    :access_token_expires_at,
    :scope,
    :is_default
  ]

  def changeset(account, attrs) do
    account
    |> cast(attrs, @fields)
    |> validate_required([:user_id, :email, :refresh_token])
    |> unique_constraint(:email)
  end
end
