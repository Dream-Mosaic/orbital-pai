defmodule App.RecipesTest do
  use App.DataCase, async: false

  alias App.Recipes
  alias App.Recipes.Recipe
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "d@x.com", name: "Alice"},
      %{email: "t@x.com", name: "Bob"}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, d} = Users.upsert_allowed("d@x.com")
    {:ok, t} = Users.upsert_allowed("t@x.com")
    %{d: d.id, t: t.id}
  end

  @lasagna %{
    title: "Lasagna",
    ingredients: ["1 lb ground beef", "12 lasagna noodles", "2 cups ricotta cheese"],
    steps: ["Preheat the oven to 375°F.", "Layer it up.", "Bake 25 minutes."]
  }

  defp save!(uid, attrs) do
    {:ok, recipe, _} = Recipes.save(uid, Map.merge(@lasagna, attrs))
    recipe
  end

  describe "normalize/1" do
    test "case, punctuation, apostrophes, articles and a trailing \"recipe\" are ignored" do
      assert Recipes.normalize("Lasagna") == "lasagna"
      assert Recipes.normalize("  The LASAGNA Recipe. ") == "lasagna"
      assert Recipes.normalize("Grandma's Lasagna!") == "grandmas lasagna"
      assert Recipes.normalize("my recipe for chili") == "chili"
      assert Recipes.normalize("our mac-and-cheese") == "mac and cheese"
    end

    test "accents fold so STT spelling drift still matches" do
      assert Recipes.normalize("Crème Brûlée") == "creme brulee"
    end

    test "nothing left is nil" do
      assert Recipes.normalize("the recipe") == nil
      assert Recipes.normalize("   ") == nil
      assert Recipes.normalize(nil) == nil
    end
  end

  describe "save/2" do
    test "is household-shared by default: both users see it", %{d: d, t: t} do
      assert {:ok, recipe, :created} = Recipes.save(d, @lasagna)
      assert recipe.household == true
      assert recipe.user_id == d
      assert recipe.name == "lasagna"
      assert recipe.title == "Lasagna"

      assert {:ok, %Recipe{id: id}} = Recipes.get(t, "lasagna")
      assert id == recipe.id
      assert Enum.map(Recipes.list(t), & &1.title) == ["Lasagna"]
    end

    test "household: false is private to its owner", %{d: d, t: t} do
      assert {:ok, recipe, :created} = Recipes.save(d, Map.put(@lasagna, :household, false))
      assert recipe.household == false

      assert {:ok, _} = Recipes.get(d, "lasagna")
      assert Recipes.get(t, "lasagna") == {:error, :not_found}
      assert Recipes.list(t) == []
    end

    test "saving the same household name again replaces it — whoever saves", %{d: d, t: t} do
      original = save!(d, %{notes: "old note"})

      assert {:ok, replaced, :replaced} =
               Recipes.save(t, %{
                 title: "The Lasagna",
                 ingredients: ["noodles"],
                 steps: ["Cook it."]
               })

      assert replaced.id == original.id
      assert replaced.title == "The Lasagna"
      assert replaced.ingredients == ["noodles"]
      assert replaced.steps == ["Cook it."]
      # A replace is the whole recipe: optional fields not given are cleared.
      assert replaced.notes == nil
      # The original author stays the owner.
      assert replaced.user_id == d
      assert Repo.aggregate(Recipe, :count) == 1
    end

    test "a plural/singular respelling replaces rather than duplicating", %{d: d} do
      save!(d, %{title: "Chocolate Chip Cookies"})

      assert {:ok, _, :replaced} =
               Recipes.save(d, Map.put(@lasagna, :title, "chocolate chip cookie"))

      assert Repo.aggregate(Recipe, :count) == 1
    end

    test "a personal recipe can share a name with the household one", %{d: d} do
      household = save!(d, %{})
      personal = save!(d, %{household: false, ingredients: ["my secret sauce"]})

      assert household.id != personal.id
      assert {:ok, %{id: id}} = Recipes.get(d, "lasagna")
      assert id == household.id, "an unqualified lookup prefers the shared household recipe"
      assert {:ok, %{id: ^id}} = Recipes.get(d, "lasagna", :household)
      assert {:ok, %{ingredients: ["my secret sauce"]}} = Recipes.get(d, "lasagna", :personal)
    end

    test "the database enforces one name per owner scope", %{d: d, t: t} do
      insert = fn attrs ->
        %Recipe{}
        |> Recipe.changeset(Map.merge(%{name: "chili", title: "Chili"}, attrs))
        |> Repo.insert()
      end

      assert {:ok, _} = insert.(%{user_id: d, household: true})
      assert {:error, cs} = insert.(%{user_id: t, household: true})
      assert {"has already been taken", _} = cs.errors[:name]

      assert {:ok, _} = insert.(%{user_id: d, household: false})
      assert {:error, cs} = insert.(%{user_id: d, household: false})
      assert {"has already been taken", _} = cs.errors[:name]
      assert {:ok, _} = insert.(%{user_id: t, household: false})
    end

    test "two users' personal recipes of the same name never collide", %{d: d, t: t} do
      assert {:ok, _, :created} = Recipes.save(d, Map.merge(@lasagna, %{household: false}))
      assert {:ok, _, :created} = Recipes.save(t, Map.merge(@lasagna, %{household: false}))

      assert {:ok, mine} = Recipes.get(d, "lasagna")
      assert {:ok, theirs} = Recipes.get(t, "lasagna")
      assert mine.user_id == d
      assert theirs.user_id == t
    end

    test "cleans ingredients and steps: trims, drops blanks, bullets and step numbers", %{d: d} do
      assert {:ok, recipe, :created} =
               Recipes.save(d, %{
                 title: "  Pancakes recipe ",
                 ingredients: ["  - 2 cups flour ", "", "• 1 egg", nil, 7],
                 steps: ["1. Mix it.", "Step 2: Fry it", "  ", "3) Eat."],
                 servings: " 4 ",
                 notes: "",
                 source: "Grandma"
               })

      assert recipe.title == "Pancakes"
      assert recipe.ingredients == ["2 cups flour", "1 egg"]
      assert recipe.steps == ["Mix it.", "Fry it", "Eat."]
      assert recipe.servings == "4"
      assert recipe.notes == nil
      assert recipe.source == "Grandma"
    end

    test "rejects a blank title, no ingredients or no steps", %{d: d} do
      assert Recipes.save(d, Map.put(@lasagna, :title, "  the recipe ")) ==
               {:error, :invalid_title}

      assert Recipes.save(d, Map.put(@lasagna, :ingredients, ["", "  "])) ==
               {:error, :missing_ingredients}

      assert Recipes.save(d, Map.delete(@lasagna, :steps)) == {:error, :missing_steps}
      assert Repo.aggregate(Recipe, :count) == 0
    end
  end

  describe "get/3 matching" do
    setup %{d: d} do
      save!(d, %{title: "Grandma's Lasagna"})
      save!(d, %{title: "Chicken Soup"})
      save!(d, %{title: "Chicken Curry"})
      save!(d, %{title: "Chocolate Chip Cookies"})
      save!(d, %{title: "Pierogi"})
      :ok
    end

    test "matches case/punctuation/article/\"recipe\"-insensitively", %{t: t} do
      for spoken <- ["grandmas lasagna", "the Grandma's Lasagna recipe", "GRANDMA'S LASAGNA."] do
        assert {:ok, %{title: "Grandma's Lasagna"}} = Recipes.get(t, spoken)
      end
    end

    test "singular and plural collide", %{t: t} do
      assert {:ok, %{title: "Chocolate Chip Cookies"}} = Recipes.get(t, "chocolate chip cookie")
    end

    test "a unique partial name finds it", %{t: t} do
      assert {:ok, %{title: "Grandma's Lasagna"}} = Recipes.get(t, "the lasagna")
      assert {:ok, %{title: "Chocolate Chip Cookies"}} = Recipes.get(t, "cookies")
    end

    test "a partial name matching several recipes is ambiguous", %{t: t} do
      assert {:error, {:ambiguous, matches}} = Recipes.get(t, "chicken")
      assert matches |> Enum.map(& &1.title) |> Enum.sort() == ["Chicken Curry", "Chicken Soup"]
    end

    test "partial matching is by whole words, not substrings", %{t: t} do
      assert Recipes.get(t, "pie") == {:error, :not_found}
    end

    test "an exact name beats a partial one", %{d: d, t: t} do
      save!(d, %{title: "Chicken"})
      assert {:ok, %{title: "Chicken"}} = Recipes.get(t, "chicken")
    end

    test "unknown or blank names are not found", %{t: t} do
      assert Recipes.get(t, "beef wellington") == {:error, :not_found}
      assert Recipes.get(t, "the recipe") == {:error, :not_found}
      assert Recipes.get(t, nil) == {:error, :not_found}
    end
  end

  describe "list/1" do
    test "own + household, never another user's personal, ordered by name", %{d: d, t: t} do
      save!(d, %{title: "Ziti"})
      save!(t, %{title: "Apple Pie", household: false})
      save!(d, %{title: "Meatloaf", household: false})

      assert Enum.map(Recipes.list(d), & &1.title) == ["Meatloaf", "Ziti"]
      assert Enum.map(Recipes.list(t), & &1.title) == ["Apple Pie", "Ziti"]
    end
  end

  describe "update/4" do
    test "appends ingredients, skipping ones already listed", %{d: d, t: t} do
      save!(d, %{})

      assert {:ok, recipe, report} =
               Recipes.update(t, "lasagna", %{
                 add_ingredients: ["3 cloves garlic", "12 Lasagna Noodles"]
               })

      assert recipe.ingredients == [
               "1 lb ground beef",
               "12 lasagna noodles",
               "2 cups ricotta cheese",
               "3 cloves garlic"
             ]

      assert report.added == ["3 cloves garlic"]
      assert report.skipped == ["12 Lasagna Noodles"]
    end

    test "removes ingredients by spoken phrase, reporting misses", %{d: d} do
      save!(d, %{})

      assert {:ok, recipe, report} =
               Recipes.update(d, "lasagna", %{remove_ingredients: ["the ricotta", "saffron"]})

      assert recipe.ingredients == ["1 lb ground beef", "12 lasagna noodles"]
      assert report.removed == ["2 cups ricotta cheese"]
      assert report.not_found == ["saffron"]
    end

    test "an exact ingredient match removes only that one", %{d: d} do
      save!(d, %{ingredients: ["cheese", "ricotta cheese"]})

      assert {:ok, recipe, %{removed: ["cheese"]}} =
               Recipes.update(d, "lasagna", %{remove_ingredients: ["Cheese"]})

      assert recipe.ingredients == ["ricotta cheese"]
    end

    test "replaces steps, replaces or appends notes, sets servings", %{d: d} do
      save!(d, %{notes: "Freezes well."})

      assert {:ok, recipe, _} =
               Recipes.update(d, "lasagna", %{
                 steps: ["1. Assemble.", "Bake 40 minutes."],
                 add_note: "Use less salt.",
                 servings: "8"
               })

      assert recipe.steps == ["Assemble.", "Bake 40 minutes."]
      assert recipe.notes == "Freezes well.\nUse less salt."
      assert recipe.servings == "8"

      assert {:ok, recipe, _} = Recipes.update(d, "lasagna", %{notes: "Only this."})
      assert recipe.notes == "Only this."
    end

    test "nothing to change, or emptying the steps, is refused", %{d: d} do
      save!(d, %{})
      assert Recipes.update(d, "lasagna", %{}) == {:error, :nothing_to_change}
      assert Recipes.update(d, "lasagna", %{steps: ["  "]}) == {:error, :missing_steps}
    end

    test "can't touch another user's personal recipe", %{d: d, t: t} do
      save!(d, %{household: false})

      assert Recipes.update(t, "lasagna", %{add_ingredients: ["salt"]}) ==
               {:error, :not_found}
    end
  end

  describe "delete/3" do
    test "either household member can delete a household recipe", %{d: d, t: t} do
      save!(d, %{})
      assert {:ok, %Recipe{title: "Lasagna"}} = Recipes.delete(t, "the lasagna recipe")
      assert Recipes.list(d) == []
    end

    test "a name in BOTH scopes is not silently resolved for a write — it asks which", %{
      d: d,
      t: t
    } do
      save!(d, %{})
      save!(t, %{household: false})

      assert {:error, {:which_scope, %Recipe{household: true}, %Recipe{household: false}}} =
               Recipes.delete(t, "my lasagna recipe")

      assert {:error, {:which_scope, _, _}} = Recipes.update(t, "lasagna", %{add_note: "x"})
      # an explicit scope goes straight through, and the shared one survives
      assert {:ok, %Recipe{household: false}} = Recipes.delete(t, "lasagna", :personal)
      assert [%Recipe{household: true}] = Recipes.list(d)
    end

    test "another user's personal recipe is invisible to delete", %{d: d, t: t} do
      save!(d, %{household: false})
      assert Recipes.delete(t, "lasagna") == {:error, :not_found}
      assert [_] = Recipes.list(d)
    end

    test "deleting a user deletes their recipes", %{d: d} do
      save!(d, %{})
      Repo.delete!(Users.get(d))
      assert Repo.aggregate(Recipe, :count) == 0
    end
  end
end
