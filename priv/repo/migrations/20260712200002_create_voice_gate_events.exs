defmodule App.Repo.Migrations.CreateVoiceGateEvents do
  use Ecto.Migration

  def change do
    create table(:voice_gate_events) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :decision, :string, null: false
      add :reason, :string
      add :score, :float
      add :speech_ms, :integer
      add :transcript, :string
      add :mode, :string, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:voice_gate_events, [:user_id, :id])
  end
end
