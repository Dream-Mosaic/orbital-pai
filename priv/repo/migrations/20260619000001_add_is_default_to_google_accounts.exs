defmodule App.Repo.Migrations.AddIsDefaultToGoogleAccounts do
  use Ecto.Migration

  def change do
    alter table(:google_accounts) do
      add :is_default, :boolean, null: false, default: false
    end
  end
end
