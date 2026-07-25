defmodule App.Repo.Migrations.CreateGoogleAccounts do
  use Ecto.Migration

  def change do
    create table(:google_accounts) do
      add :email, :string, null: false
      add :label, :string
      add :refresh_token, :text, null: false
      add :access_token, :text
      add :access_token_expires_at, :utc_datetime
      add :scope, :text
      timestamps(type: :utc_datetime)
    end

    create unique_index(:google_accounts, [:email])
  end
end
