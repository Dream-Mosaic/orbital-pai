defmodule App.Repo.Migrations.TurnsRemindersUserId do
  use Ecto.Migration

  def up do
    execute "DELETE FROM turns"
    execute "DELETE FROM reminders"

    # SQLite can't DROP a column while an index references it — drop the session_id indexes first.
    drop index(:turns, [:session_id])
    drop index(:reminders, [:session_id])

    alter table(:turns) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      remove :session_id
    end

    alter table(:reminders) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      remove :session_id
    end

    create index(:turns, [:user_id])
    create index(:reminders, [:user_id])
  end

  def down do
    drop index(:turns, [:user_id])
    drop index(:reminders, [:user_id])

    alter table(:turns) do
      remove :user_id
      add :session_id, :string
    end

    alter table(:reminders) do
      remove :user_id
      add :session_id, :string, default: "default"
    end

    create index(:turns, [:session_id])
    create index(:reminders, [:session_id])
  end
end
