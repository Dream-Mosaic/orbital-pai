defmodule App.Repo.Migrations.CreateHouseholdMessages do
  use Ecto.Migration

  def change do
    create table(:household_messages) do
      add :from_user_id, references(:users, on_delete: :delete_all), null: false
      add :to_user_id, references(:users, on_delete: :delete_all), null: false
      add :body, :text, null: false
      # nil until the recipient's Conversation starts speaking it (the agenda item's ack)
      add :delivered_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    # pull-on-connect: "this user's undelivered messages, oldest first"
    create index(:household_messages, [:to_user_id, :delivered_at])
    # check_household_messages: "my recent sent messages"
    create index(:household_messages, [:from_user_id])
  end
end
