defmodule App.Repo.Migrations.AddHeadsUpToUsers do
  use Ecto.Migration

  # Calendar heads-ups default ON. Unlike voice_activation (added default false, flipped later by
  # its own UPDATE migration), this column is born with default true + NOT NULL, and SQLite's
  # ADD COLUMN fills every existing row with that default — so existing users are backfilled ON by
  # this one statement, with no separate UPDATE to keep in step.
  def change do
    alter table(:users) do
      add :heads_up, :boolean, default: true, null: false
    end
  end
end
