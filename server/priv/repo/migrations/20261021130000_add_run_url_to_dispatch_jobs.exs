defmodule App.Repo.Migrations.AddRunUrlToDispatchJobs do
  use Ecto.Migration

  # The run log link the box sends in its callbacks (built from the forge's public server_url).
  def change do
    alter table(:dispatch_jobs) do
      add :run_url, :text
    end
  end
end
