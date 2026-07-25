defmodule App.Repo.Migrations.AddVoicePrefsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :default_abi, :boolean, default: false, null: false
      add :default_ptt, :boolean, default: false, null: false
    end
  end
end
