defmodule App.Repo.Migrations.AddVoiceActivationToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :voice_activation, :boolean, default: false, null: false
    end
  end
end
