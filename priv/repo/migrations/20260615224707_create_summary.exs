defmodule App.Repo.Migrations.CreateSummary do
  use Ecto.Migration

  def change do
    create table(:summary) do
      add :content, :text, null: false, default: ""
      timestamps(type: :utc_datetime)
    end
  end
end
