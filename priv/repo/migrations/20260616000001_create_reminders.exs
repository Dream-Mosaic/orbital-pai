defmodule App.Repo.Migrations.CreateReminders do
  use Ecto.Migration

  def change do
    create table(:reminders) do
      add :session_id, :string, null: false, default: "default"
      add :body, :text, null: false
      add :due_at, :utc_datetime, null: false
      add :fired_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    # The scheduler queries unfired reminders whose time has come.
    create index(:reminders, [:fired_at, :due_at])
    create index(:reminders, [:session_id])
  end
end
