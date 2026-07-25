defmodule App.Repo.Migrations.AddHouseholdToReminders do
  use Ecto.Migration

  def change do
    alter table(:reminders) do
      add :household, :boolean, default: false, null: false
    end
  end
end
