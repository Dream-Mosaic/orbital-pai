defmodule App.Repo.Migrations.AddRecurrenceToReminders do
  use Ecto.Migration

  def change do
    alter table(:reminders) do
      # Ecto :map — ecto_sqlite3 stores it as TEXT holding JSON. NULL = one-shot,
      # which is every pre-existing row, so no backfill is needed.
      add :recurrence, :map
    end
  end
end
