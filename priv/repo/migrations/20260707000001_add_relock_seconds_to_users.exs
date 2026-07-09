defmodule App.Repo.Migrations.AddRelockSecondsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :relock_seconds, :integer, default: 15, null: false
    end
  end
end
