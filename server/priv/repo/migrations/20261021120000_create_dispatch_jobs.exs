defmodule App.Repo.Migrations.CreateDispatchJobs do
  use Ecto.Migration

  def change do
    create table(:dispatch_jobs) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :repo, :string, null: false
      add :issue, :integer, null: false
      add :run_id, :integer
      add :run_number, :integer
      add :status, :string, null: false, default: "queued"
      add :branch, :string
      add :pr_url, :text
      add :summary, :text
      add :reason, :text
      add :notified_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:dispatch_jobs, [:user_id, :status])
    create index(:dispatch_jobs, [:repo, :issue])
  end
end
