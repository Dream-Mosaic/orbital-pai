defmodule App.Repo.Migrations.CreateRoutines do
  use Ecto.Migration

  def change do
    create table(:routines) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # match key (lowercase, punctuation/space-free) — the replace-by-name identity
      add :name, :string, null: false
      # the name as the user said it, for read-back and the brain prompt
      add :label, :string, null: false
      # ecto_sqlite3 stores {:array, :string} as JSON text
      add :triggers, {:array, :string}, null: false, default: "[]"
      add :steps, :text, null: false
      add :last_run_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:routines, [:user_id, :name])
  end
end
