defmodule App.Tools.RecipesTest do
  use App.DataCase, async: false
  alias App.Recipes
  alias App.Tools.Recipes, as: Tool
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "d@x.com", name: "Alice"},
      %{email: "t@x.com", name: "Bob"}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, u} = Users.upsert_allowed("d@x.com")
    {:ok, other} = Users.upsert_allowed("t@x.com")
    %{user: u, other: other}
  end

  defp ctx(user),
    do: %{session_id: to_string(user.id), user_id: user.id, config: App.Config.default()}

  defp no_session, do: %{session_id: "default", user_id: nil, config: App.Config.default()}

  # Every {:ok, map} result goes back into the next Gemini request as JSON.
  defp json!(result), do: result |> Jason.encode!() |> Jason.decode!()

  @lasagna %{
    "title" => "Grandma's Lasagna",
    "ingredients" => ["1 lb ground beef", "12 lasagna noodles", "2 cups ricotta cheese"],
    "steps" => [
      "Preheat the oven to 375°F.",
      "Brown the beef, about 8 minutes.",
      "Layer noodles, sauce and ricotta.",
      "Bake 25 to 30 minutes, then rest 10 min."
    ],
    "servings" => "8",
    "source" => "Grandma"
  }

  defp save!(user, args \\ %{}) do
    {:ok, %{saved: true}} = Tool.execute("save_recipe", Map.merge(@lasagna, args), ctx(user))
  end

  describe "registration" do
    test "declares the five recipe functions with their required args" do
      decls = Map.new(Tool.declarations(), &{&1.name, &1})

      assert Map.keys(decls) |> Enum.sort() ==
               ~w(delete_recipe edit_recipe get_recipe list_recipes save_recipe)

      assert decls["save_recipe"].parameters.required == ["title", "ingredients", "steps"]
      assert decls["get_recipe"].parameters.required == ["name"]
      assert decls["get_recipe"].parameters.properties.step.type == "integer"
      assert decls["list_recipes"].parameters.required == []
      assert decls["edit_recipe"].parameters.required == ["name"]
      assert decls["delete_recipe"].parameters.required == ["name"]
    end

    test "is enabled (last) in the default config and advertises itself in the brain prompt" do
      assert List.last(App.Config.default().tools) == App.Tools.Recipes

      prompt = Tool.prompt()

      for name <- ~w(save_recipe get_recipe add_to_list set_timer delete_recipe) do
        assert prompt =~ name
      end

      assert prompt =~ ~r/one step/i
      # cook mode names the step it is about to read, so its card can show that step
      assert prompt =~ "get_recipe with `step`"
      assert App.Tools.prompt_block(App.Config.default()) =~ prompt
    end

    test "no bridge phrases (DB-local, fast)" do
      assert Tool.bridge("get_recipe") == []
      assert Tool.bridge("save_recipe") == []
    end
  end

  test "every function is a no-op note without a user session" do
    for name <- ~w(save_recipe get_recipe list_recipes edit_recipe delete_recipe) do
      assert {:ok, %{note: note}} = Tool.execute(name, @lasagna, no_session())
      assert note =~ "no user session"
    end

    assert Recipes.list(0) == []
  end

  describe "save_recipe" do
    test "saves to the household by default and reads back the counts", %{user: u, other: o} do
      assert {:ok, result} = Tool.execute("save_recipe", @lasagna, ctx(u))

      assert %{
               "saved" => true,
               "replaced" => false,
               "title" => "Grandma's Lasagna",
               "personal" => false,
               "ingredient_count" => 3,
               "step_count" => 4,
               # the saved recipe itself, in get_recipe's shape: what its card shows
               "recipe" => %{"title" => "Grandma's Lasagna", "steps" => [_, _, _, _]}
             } = json!(result)

      assert [%{title: "Grandma's Lasagna"}] = Recipes.list(o.id)
    end

    test "personal: true keeps it private to the saver", %{user: u, other: o} do
      assert {:ok, %{saved: true, personal: true}} =
               Tool.execute("save_recipe", Map.put(@lasagna, "personal", true), ctx(u))

      assert [_] = Recipes.list(u.id)
      assert Recipes.list(o.id) == []
    end

    test "won't overwrite an existing recipe without replace: true", %{user: u, other: o} do
      save!(u)

      new_version = %{@lasagna | "ingredients" => ["noodles"], "title" => "grandmas lasagna"}

      assert {:ok, result} = Tool.execute("save_recipe", new_version, ctx(o))
      assert result.saved == false
      assert result.exists == true
      assert result.title == "Grandma's Lasagna"
      assert result.note =~ "replace"
      assert {:ok, %{ingredients: [_, _, _]}} = Recipes.get(u.id, "lasagna")

      assert {:ok, %{saved: true, replaced: true, ingredient_count: 1}} =
               Tool.execute("save_recipe", Map.put(new_version, "replace", true), ctx(o))

      assert {:ok, %{ingredients: ["noodles"]}} = Recipes.get(u.id, "lasagna")
    end

    test "a personal save doesn't collide with the household namesake", %{user: u} do
      save!(u)

      assert {:ok, %{saved: true, replaced: false, personal: true}} =
               Tool.execute("save_recipe", Map.put(@lasagna, "personal", true), ctx(u))
    end

    test "validates title, ingredients and steps", %{user: u} do
      assert Tool.execute("save_recipe", Map.delete(@lasagna, "title"), ctx(u)) ==
               {:error, :missing_args}

      assert Tool.execute("save_recipe", %{@lasagna | "title" => "  "}, ctx(u)) ==
               {:error, :invalid_title}

      assert Tool.execute("save_recipe", %{@lasagna | "ingredients" => []}, ctx(u)) ==
               {:error, :missing_ingredients}

      assert Tool.execute("save_recipe", %{@lasagna | "steps" => "just cook it"}, ctx(u)) ==
               {:error, :missing_steps}

      assert Recipes.list(u.id) == []
    end
  end

  describe "get_recipe" do
    test "returns the full recipe with numbered steps and their durations", %{user: u, other: o} do
      save!(u, %{"notes" => "Freezes well."})

      assert {:ok, result} = Tool.execute("get_recipe", %{"name" => "the lasagna"}, ctx(o))

      assert json!(result) == %{
               "title" => "Grandma's Lasagna",
               "personal" => false,
               "servings" => "8",
               "source" => "Grandma",
               "notes" => "Freezes well.",
               "ingredient_count" => 3,
               "ingredients" => [
                 "1 lb ground beef",
                 "12 lasagna noodles",
                 "2 cups ricotta cheese"
               ],
               "step_count" => 4,
               "steps" => [
                 %{"number" => 1, "text" => "Preheat the oven to 375°F.", "durations" => []},
                 %{
                   "number" => 2,
                   "text" => "Brown the beef, about 8 minutes.",
                   "durations" => ["8 minutes"]
                 },
                 %{
                   "number" => 3,
                   "text" => "Layer noodles, sauce and ricotta.",
                   "durations" => []
                 },
                 %{
                   "number" => 4,
                   "text" => "Bake 25 to 30 minutes, then rest 10 min.",
                   "durations" => ["25 to 30 minutes", "10 min"]
                 }
               ]
             }
    end

    test "not found lists what IS saved", %{user: u} do
      save!(u)

      assert {:ok, result} = Tool.execute("get_recipe", %{"name" => "meatloaf"}, ctx(u))
      assert result.note =~ "no recipe called \"meatloaf\""
      assert result.recipes == ["Grandma's Lasagna"]
    end

    test "an ambiguous name asks which", %{user: u} do
      save!(u, %{"title" => "Chicken Soup"})
      save!(u, %{"title" => "Chicken Curry"})

      assert {:ok, result} = Tool.execute("get_recipe", %{"name" => "chicken"}, ctx(u))
      assert result.note =~ "which"
      assert result.matches == ["Chicken Curry", "Chicken Soup"]
    end

    test "another user's personal recipe is invisible; personal: true reaches your own", %{
      user: u,
      other: o
    } do
      save!(u)
      save!(u, %{"personal" => true, "servings" => "2"})

      assert {:ok, %{personal: false, servings: "8"}} =
               Tool.execute("get_recipe", %{"name" => "lasagna"}, ctx(u))

      assert {:ok, %{personal: true, servings: "2"}} =
               Tool.execute("get_recipe", %{"name" => "lasagna", "personal" => true}, ctx(u))

      assert {:ok, %{note: _}} =
               Tool.execute("get_recipe", %{"name" => "lasagna", "personal" => true}, ctx(o))
    end

    test "a name is required", %{user: u} do
      assert Tool.execute("get_recipe", %{}, ctx(u)) == {:error, :missing_args}
    end

    test "cook mode: `step` names the step being read, clamped to the recipe", %{user: u} do
      save!(u)

      get = fn step ->
        Tool.execute("get_recipe", %{"name" => "lasagna", "step" => step}, ctx(u))
      end

      assert {:ok, %{current_step: 3, step_count: 4, steps: [_, _, _, _]}} = get.(3)
      assert {:ok, %{current_step: 4}} = get.(9)
      assert {:ok, %{current_step: 1}} = get.(0)
      assert {:ok, %{current_step: 1}} = get.(-2)
      # JSON numbers can arrive as floats, and a model sometimes quotes them
      assert {:ok, %{current_step: 2}} = get.(2.0)
      assert {:ok, %{current_step: 2}} = get.(" 2 ")

      # anything else is not a step: the plain recipe, no cook-mode marker
      for junk <- ["next", "", nil, true, 2.5, %{}] do
        assert {:ok, result} = get.(junk)
        refute Map.has_key?(result, :current_step), inspect(junk)
      end

      assert {:ok, result} = Tool.execute("get_recipe", %{"name" => "lasagna"}, ctx(u))
      refute Map.has_key?(result, :current_step)
    end
  end

  describe "durations/1" do
    test "pulls every spoken duration out of a step" do
      assert Tool.durations("Simmer for an hour, stirring.") == ["an hour"]
      assert Tool.durations("Let it rise 1 1/2 hours.") == ["1 1/2 hours"]
      assert Tool.durations("Bake 25-30 mins.") == ["25-30 mins"]

      assert Tool.durations("Whisk for half a minute, then rest 45 seconds") == [
               "half a minute",
               "45 seconds"
             ]

      assert Tool.durations("Add 2 cups of minced garlic.") == []
    end
  end

  describe "list_recipes" do
    test "summaries of the visible recipes", %{user: u, other: o} do
      assert {:ok, %{recipes: [], note: "no recipes saved yet"}} =
               Tool.execute("list_recipes", %{}, ctx(u))

      save!(u)
      save!(o, %{"title" => "Apple Pie", "personal" => true})

      assert {:ok, result} = Tool.execute("list_recipes", %{}, ctx(o))

      assert json!(result) == %{
               "count" => 2,
               "recipes" => [
                 %{
                   "title" => "Apple Pie",
                   "personal" => true,
                   "servings" => "8",
                   "ingredient_count" => 3,
                   "step_count" => 4
                 },
                 %{
                   "title" => "Grandma's Lasagna",
                   "personal" => false,
                   "servings" => "8",
                   "ingredient_count" => 3,
                   "step_count" => 4
                 }
               ]
             }

      assert {:ok, %{count: 1}} = Tool.execute("list_recipes", %{}, ctx(u))
    end
  end

  describe "edit_recipe" do
    test "adds and removes ingredients and reports what happened", %{user: u, other: o} do
      save!(u)

      assert {:ok, result} =
               Tool.execute(
                 "edit_recipe",
                 %{
                   "name" => "lasagna",
                   "add_ingredients" => ["3 cloves garlic"],
                   "remove_ingredients" => ["ricotta", "saffron"]
                 },
                 ctx(o)
               )

      assert result.edited == true
      assert result.added == ["3 cloves garlic"]
      assert result.removed == ["2 cups ricotta cheese"]
      assert result.not_found == ["saffron"]

      assert result.recipe.ingredients == [
               "1 lb ground beef",
               "12 lasagna noodles",
               "3 cloves garlic"
             ]

      assert json!(result)["recipe"]["title"] == "Grandma's Lasagna"
    end

    test "replaces steps and notes, appends a note", %{user: u} do
      save!(u, %{"notes" => "Old."})

      assert {:ok, %{recipe: recipe}} =
               Tool.execute(
                 "edit_recipe",
                 %{"name" => "lasagna", "replace_steps" => ["Assemble.", "Bake 40 minutes."]},
                 ctx(u)
               )

      assert [%{number: 1}, %{number: 2, durations: ["40 minutes"]}] = recipe.steps

      assert {:ok, %{recipe: %{notes: "Old.\nUse less salt."}}} =
               Tool.execute(
                 "edit_recipe",
                 %{"name" => "lasagna", "add_note" => "Use less salt."},
                 ctx(u)
               )

      assert {:ok, %{recipe: %{notes: "New."}}} =
               Tool.execute("edit_recipe", %{"name" => "lasagna", "notes" => "New."}, ctx(u))
    end

    test "nothing to change, unknown and ambiguous names", %{user: u} do
      save!(u, %{"title" => "Chicken Soup"})
      save!(u, %{"title" => "Chicken Curry"})

      assert Tool.execute("edit_recipe", %{"name" => "chicken soup"}, ctx(u)) ==
               {:error, :nothing_to_change}

      assert {:ok, %{note: note}} =
               Tool.execute("edit_recipe", %{"name" => "flan", "add_note" => "x"}, ctx(u))

      assert note =~ "no recipe called"

      assert {:ok, %{matches: ["Chicken Curry", "Chicken Soup"]}} =
               Tool.execute("edit_recipe", %{"name" => "chicken", "add_note" => "x"}, ctx(u))
    end
  end

  describe "delete_recipe" do
    test "deletes it and says which", %{user: u, other: o} do
      save!(u)

      assert {:ok, %{deleted: "Grandma's Lasagna", personal: false}} =
               Tool.execute("delete_recipe", %{"name" => "grandma's lasagna"}, ctx(o))

      assert Recipes.list(u.id) == []

      assert {:ok, %{note: note}} =
               Tool.execute("delete_recipe", %{"name" => "grandma's lasagna"}, ctx(o))

      assert note =~ "nothing deleted"
    end
  end
end
