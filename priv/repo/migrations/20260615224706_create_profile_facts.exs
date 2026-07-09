defmodule App.Repo.Migrations.CreateProfileFacts do
  use Ecto.Migration

  def change do
    create table(:profile_facts) do
      add :category, :string
      add :content, :text, null: false
      add :source, :string, null: false, default: "auto"
      timestamps(type: :utc_datetime)
    end
  end
end
