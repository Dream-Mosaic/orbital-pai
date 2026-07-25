defmodule App.Repo.Migrations.AddVoiceLockToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :voice_lock_mode, :string, default: "off", null: false
      add :voice_lock_threshold, :float
    end
  end
end
