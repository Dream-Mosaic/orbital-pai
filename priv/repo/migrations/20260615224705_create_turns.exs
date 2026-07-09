defmodule App.Repo.Migrations.CreateTurns do
  use Ecto.Migration

  def change do
    create table(:turns) do
      add :session_id, :string, null: false
      add :user_text, :text
      add :reflex_text, :text
      add :brain_text, :text
      add :reflex_ms, :integer
      add :brain_ms, :integer
      add :ttfa_ms, :integer
      add :ttb_ms, :integer
      timestamps(type: :utc_datetime)
    end

    create index(:turns, [:session_id])
    create index(:turns, [:inserted_at])
  end
end
