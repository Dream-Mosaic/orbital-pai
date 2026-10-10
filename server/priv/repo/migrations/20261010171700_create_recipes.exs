defmodule App.Repo.Migrations.CreateRecipes do
  use Ecto.Migration

  def change do
    create table(:recipes) do
      # Who saved it. For a household recipe this is just the original author — every member
      # sees (and can edit) it.
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # Household-shared by default (like lists); false = private to `user_id`.
      add :household, :boolean, default: true, null: false
      # The normalized match key (`App.Recipes.normalize/1`: "Grandma's Lasagna Recipe" →
      # "grandmas lasagna"); `title` keeps the name as the user said it, for read-back.
      add :name, :string, null: false
      add :title, :string, null: false
      # ecto_sqlite3 stores {:array, :string} as TEXT holding a JSON array.
      add :ingredients, {:array, :string}, default: "[]", null: false
      add :steps, {:array, :string}, default: "[]", null: false
      add :servings, :string
      add :notes, :text
      add :source, :string
      timestamps(type: :utc_datetime)
    end

    # Uniqueness is per OWNER SCOPE, so two partial indexes rather than one:
    #   * household recipes: one per name for the whole house — there is ONE household
    #     "lasagna", whoever saved it (saving it again replaces it);
    #   * personal recipes: one per name per user — David's private "lasagna" and Tanya's
    #     private "lasagna" never see each other, so they must not collide.
    # A personal recipe MAY share a name with a household one (a private variant of the house
    # recipe); lookups prefer the household one unless asked for the personal one.
    # The index names are ecto_sqlite3's defaults for these columns, which is what its
    # "UNIQUE constraint failed: recipes.name" error maps back to for `unique_constraint/3`.
    create unique_index(:recipes, [:name],
             where: "household = 1",
             name: :recipes_name_index
           )

    create unique_index(:recipes, [:user_id, :name],
             where: "household = 0",
             name: :recipes_user_id_name_index
           )
  end
end
