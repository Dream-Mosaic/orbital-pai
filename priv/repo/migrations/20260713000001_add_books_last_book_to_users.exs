defmodule App.Repo.Migrations.AddBooksLastBookToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :books_last_book, :string
    end
  end
end
