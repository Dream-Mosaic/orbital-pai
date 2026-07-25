defmodule App.Repo.Migrations.CreateTurnsFts do
  use Ecto.Migration

  def up do
    execute """
    CREATE VIRTUAL TABLE turns_fts USING fts5(
      user_text, brain_text, content=turns, content_rowid=id
    )
    """

    execute """
    CREATE TRIGGER turns_ai AFTER INSERT ON turns BEGIN
      INSERT INTO turns_fts(rowid, user_text, brain_text)
      VALUES (new.id, new.user_text, new.brain_text);
    END
    """

    execute """
    CREATE TRIGGER turns_ad AFTER DELETE ON turns BEGIN
      INSERT INTO turns_fts(turns_fts, rowid, user_text, brain_text)
      VALUES ('delete', old.id, old.user_text, old.brain_text);
    END
    """

    execute """
    CREATE TRIGGER turns_au AFTER UPDATE ON turns BEGIN
      INSERT INTO turns_fts(turns_fts, rowid, user_text, brain_text)
      VALUES ('delete', old.id, old.user_text, old.brain_text);
      INSERT INTO turns_fts(rowid, user_text, brain_text)
      VALUES (new.id, new.user_text, new.brain_text);
    END
    """

    # backfill existing rows
    execute "INSERT INTO turns_fts(rowid, user_text, brain_text) SELECT id, user_text, brain_text FROM turns"
  end

  def down do
    execute "DROP TRIGGER turns_au"
    execute "DROP TRIGGER turns_ad"
    execute "DROP TRIGGER turns_ai"
    execute "DROP TABLE turns_fts"
  end
end
