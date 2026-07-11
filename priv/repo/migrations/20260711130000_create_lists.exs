defmodule App.Repo.Migrations.CreateLists do
  use Ecto.Migration

  def change do
    create table(:lists) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :household, :boolean, default: false, null: false
      add :name, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:lists, [:user_id])
    create index(:lists, [:household])

    create table(:list_items) do
      add :list_id, references(:lists, on_delete: :delete_all), null: false
      add :text, :string, null: false
      add :checked_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:list_items, [:list_id])
  end
end
