defmodule App.Repo.Migrations.CreateTimers do
  use Ecto.Migration

  def change do
    create table(:timers) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :label, :string
      add :duration_ms, :integer, null: false
      add :ends_at, :utc_datetime_usec, null: false
      add :state, :string, default: "running", null: false
      add :fired_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:timers, [:user_id, :state])
    # The scheduler's boot reload reads every running/ringing timer across users.
    create index(:timers, [:state])
  end
end
