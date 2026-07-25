defmodule App.Repo.Migrations.AddAcknowledgedAtToReminders do
  use Ecto.Migration

  def change do
    alter table(:reminders) do
      add :acknowledged_at, :utc_datetime
    end
  end
end
