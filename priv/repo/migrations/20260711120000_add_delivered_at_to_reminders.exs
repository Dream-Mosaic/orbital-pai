defmodule App.Repo.Migrations.AddDeliveredAtToReminders do
  use Ecto.Migration

  def up do
    alter table(:reminders) do
      add :delivered_at, :utc_datetime
    end

    # Old `acknowledged_at` meant "Henry delivered it" — copy it to the new delivered_at.
    execute "UPDATE reminders SET delivered_at = acknowledged_at WHERE acknowledged_at IS NOT NULL"

    # Treat every pre-existing FIRED reminder as acknowledged (history), so the ack feature starts
    # fresh from deploy and Henry doesn't re-ask about a pile of old reminders.
    execute "UPDATE reminders SET acknowledged_at = fired_at WHERE fired_at IS NOT NULL AND acknowledged_at IS NULL"
  end

  def down do
    alter table(:reminders) do
      remove :delivered_at
    end
  end
end
