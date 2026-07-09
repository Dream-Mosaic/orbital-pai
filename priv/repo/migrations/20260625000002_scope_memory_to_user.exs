defmodule App.Repo.Migrations.ScopeMemoryToUser do
  use Ecto.Migration

  def up do
    # start fresh: these were global/singleton
    execute "DELETE FROM profile_facts"
    execute "DELETE FROM summary"

    alter table(:profile_facts) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
    end

    alter table(:summary) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
    end

    create index(:profile_facts, [:user_id])
    create unique_index(:summary, [:user_id])
  end

  def down do
    drop index(:profile_facts, [:user_id])
    drop unique_index(:summary, [:user_id])
    alter table(:profile_facts), do: remove(:user_id)
    alter table(:summary), do: remove(:user_id)
  end
end
