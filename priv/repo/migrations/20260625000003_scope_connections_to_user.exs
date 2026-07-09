defmodule App.Repo.Migrations.ScopeConnectionsToUser do
  use Ecto.Migration
  import Ecto.Query

  def up do
    alter table(:google_accounts) do
      add :user_id, references(:users, on_delete: :delete_all)
    end

    flush()

    # Only seed users + backfill when there are existing connections to assign. A fresh DB
    # (e.g. the test database) has no orphan rows, so we leave the users table untouched there.
    orphans = App.Repo.aggregate(from(a in "google_accounts", where: is_nil(a.user_id)), :count)

    if orphans > 0 do
      primary = App.Users.ensure_allowlisted()

      if primary do
        App.Repo.update_all(
          from(a in "google_accounts", where: is_nil(a.user_id)),
          set: [user_id: primary.id]
        )
      end
    end

    create index(:google_accounts, [:user_id])
  end

  def down do
    drop index(:google_accounts, [:user_id])
    alter table(:google_accounts), do: remove(:user_id)
  end
end
