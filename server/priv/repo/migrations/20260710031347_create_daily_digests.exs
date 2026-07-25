defmodule App.Repo.Migrations.CreateDailyDigests do
  use Ecto.Migration

  def change do
    create table(:daily_digests) do
      add :user_id, :integer, null: false
      add :date, :date, null: false
      add :content, :text, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:daily_digests, [:user_id, :date])
  end
end
