defmodule App.Repo.Migrations.AddOidcSubjectToUsers do
  use Ecto.Migration

  def change do
    # Nullable: every existing row predates Authentik and has no subject until its owner logs in
    # once (App.Users.upsert_from_oidc/1 step 3 binds it). Unique: two rows claiming one subject
    # is exactly the corruption the subject-keyed scheme exists to prevent.
    alter table(:users) do
      add :oidc_subject, :string
    end

    create unique_index(:users, [:oidc_subject])
  end
end
