defmodule App.Repo.Migrations.CreateTrackers do
  use Ecto.Migration

  def change do
    create table(:trackers) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # The normalized match key (lowercased, trimmed, last word singularized: "Headaches" →
      # "headache"); `label` keeps the user's own words for read-back.
      add :name, :string, null: false
      add :label, :string, null: false
      add :unit, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:trackers, [:user_id, :name])

    create table(:tracker_entries) do
      add :tracker_id, references(:trackers, on_delete: :delete_all), null: false
      add :recorded_at, :utc_datetime_usec, null: false
      add :value, :float
      add :note, :text
      # ecto_sqlite3 stores {:array, :string} as TEXT holding a JSON array (same storage as the
      # :map recurrence column on reminders).
      add :tags, {:array, :string}, default: "[]", null: false
      timestamps(type: :utc_datetime)
    end

    create index(:tracker_entries, [:tracker_id, :recorded_at])
  end
end
