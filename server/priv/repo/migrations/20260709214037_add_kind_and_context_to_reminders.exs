defmodule App.Repo.Migrations.AddKindAndContextToReminders do
  use Ecto.Migration

  def change do
    alter table(:reminders) do
      add :kind, :string, default: "reminder", null: false
      add :context, :string
    end
  end
end
