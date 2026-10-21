defmodule App.Repo.Migrations.AddReadErrorSinceToDispatchJobs do
  use Ecto.Migration

  # When the watchdog's forge reads for a job started failing (nil after a good read), so it
  # marks the job lost only after 24 h of failures in a row.
  def change do
    alter table(:dispatch_jobs) do
      add :read_error_since, :utc_datetime
    end
  end
end
