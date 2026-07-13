defmodule App.Repo.Migrations.CreateVoiceEnrollments do
  use Ecto.Migration

  def change do
    create table(:voice_enrollments) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :slot, :integer, null: false
      add :audio, :binary, null: false
      add :embedding, :binary, null: false
      add :model_id, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:voice_enrollments, [:user_id, :slot])
  end
end
