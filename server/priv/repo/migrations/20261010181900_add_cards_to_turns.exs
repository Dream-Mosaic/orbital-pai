defmodule App.Repo.Migrations.AddCardsToTurns do
  use Ecto.Migration

  def change do
    alter table(:turns) do
      # The visual cards (App.Cards) the user saw during the turn, oldest first, so a history
      # replay can put them back in the thread. ecto_sqlite3 stores {:array, :map} as TEXT
      # holding a JSON array. NULL = the turn showed no cards, which is every pre-existing
      # row, so no backfill is needed. Display-only: turns_fts and the embedder index
      # user_text/brain_text and never read this column.
      add :cards, {:array, :map}
    end
  end
end
