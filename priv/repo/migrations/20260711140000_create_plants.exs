defmodule App.Repo.Migrations.CreatePlants do
  use Ecto.Migration

  def change do
    create table(:plants) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :household, :boolean, default: false, null: false
      add :name, :string, null: false
      add :species, :string
      add :location, :string
      add :count, :integer
      add :planted_on, :date
      add :status, :string, default: "active", null: false
      add :season, :string
      add :archived_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:plants, [:user_id])
    create index(:plants, [:household])
    create index(:plants, [:status])

    create table(:plant_notes) do
      add :plant_id, references(:plants, on_delete: :delete_all), null: false
      add :body, :string, null: false
      add :noted_on, :date
      timestamps(type: :utc_datetime)
    end

    create index(:plant_notes, [:plant_id])
  end
end
