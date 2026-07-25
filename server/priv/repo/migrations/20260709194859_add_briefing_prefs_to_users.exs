defmodule App.Repo.Migrations.AddBriefingPrefsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :briefing_time, :string
      add :briefing_last_on, :date
    end
  end
end
