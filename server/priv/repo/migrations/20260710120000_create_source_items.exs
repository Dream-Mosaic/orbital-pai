defmodule App.Repo.Migrations.CreateSourceItems do
  use Ecto.Migration

  def change do
    create table(:source_items) do
      add :user_id, :id, null: false
      add :account_id, :id, null: false
      add :source, :string, null: false
      add :external_id, :string, null: false
      add :content_hash, :string, null: false
      # the item's own timestamp (email date / event start) — used by the Gmail age-out sweep.
      add :at, :utc_datetime
      add :indexed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime)
    end

    create unique_index(:source_items, [:user_id, :source, :account_id, :external_id])
    create index(:source_items, [:user_id, :source, :account_id])
    create index(:source_items, [:source, :at])
  end
end
