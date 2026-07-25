defmodule App.Repo.Migrations.AddEmbeddedAtToTurnsAndDigests do
  use Ecto.Migration

  def change do
    alter table(:turns) do
      add :embedded_at, :utc_datetime_usec
    end

    alter table(:daily_digests) do
      add :embedded_at, :utc_datetime_usec
    end

    create index(:turns, [:embedded_at])
    create index(:daily_digests, [:embedded_at])
  end
end
