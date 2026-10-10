defmodule App.Repo.Migrations.AddWhatsNewSeenToUsers do
  use Ecto.Migration

  # The release tag of the last "what's new" note Henry spoke to this user (App.Agenda.WhatsNew).
  # NULL = never heard one, so every existing user hears the current one once.
  def change do
    alter table(:users) do
      add :whats_new_seen, :string
    end
  end
end
