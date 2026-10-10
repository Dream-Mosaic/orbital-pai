defmodule App.Tools.Recipes do
  @moduledoc """
  The recipe-book tool: save a recipe (dictated, pasted, or structured by the brain from a web
  page), read one back for "what do I need for lasagna?" or for pushing its ingredients onto the
  groceries list, list them, edit one ("add garlic to the lasagna"), delete one — and COOK MODE,
  which is pure prompt: the brain fetches the recipe and walks it one step per turn, offering a
  `set_timer` when a step is timed (each step carries its spoken `durations` to make that easy).

  Recipes are HOUSEHOLD-SHARED by default (`App.Recipes`); `personal: true` keeps one private.
  On get/edit/delete, `personal` narrows the lookup (true → only the caller's private ones,
  false → only the household's); omitted, the caller's whole visible set is searched and a
  household recipe wins over a same-named personal one.

  Tool results do not survive between turns (history is just the spoken text), so cook mode
  re-fetches the recipe each turn — it's a local DB read — and keys off the step number it
  last said, passing the one it's about to read as `step`: the result then carries
  `current_step`, which `App.Cards` shows as that single step, large, for the kitchen.
  """
  @behaviour App.Tools.Tool

  alias App.Recipes

  @impl true
  def prompt do
    "Recipes live in a household-shared recipe book (save_recipe, get_recipe, list_recipes, " <>
      "edit_recipe, delete_recipe); pass personal: true only when they ask to keep one " <>
      "private — \"save my lasagna recipe\" still means the shared book. To save one, " <>
      "dictated, pasted, or read off a web page or a web search, structure it yourself into " <>
      "ingredients (with quantities) and plain steps, read back the title with the " <>
      "ingredient and step counts, and call save_recipe only once they confirm; if it says " <>
      "one already exists, ask before saving again with replace: true. For \"what do I need " <>
      "for X\" call get_recipe and list the ingredients briefly; to put a recipe on the " <>
      "groceries, get_recipe and then call add_to_list ONCE with list \"groceries\" and " <>
      "every ingredient in `items`, leaving out pantry staples only if they say so. COOK " <>
      "MODE (\"walk me through it\", \"let's make X\"): speak ONE step per turn, plainly and " <>
      "briefly, starting with its number (\"Step 3 — …\"), then wait for \"next\"/\"okay\"; " <>
      "recipe results don't carry over between turns, so call get_recipe with `step` = the " <>
      "step you're about to read EVERY turn (1 to start, the last number you said + 1 on " <>
      "\"next\", the same number on \"repeat that\") — it puts that step on their screen; " <>
      "\"what temperature\"/\"how long\" is answered from the recipe. When a step has " <>
      "durations, offer a timer (\"bake 25 minutes — want a timer?\") and call set_timer " <>
      "only on a yes; call delete_recipe only after they confirm."
  end

  @impl true
  def bridge(_name), do: []

  @impl true
  def declarations do
    [
      %{
        name: "save_recipe",
        description:
          "Save a recipe to the recipe book (household-shared unless personal). Only after " <>
            "reading the title + ingredient and step counts back and the user confirming. " <>
            "Refuses to overwrite an existing recipe of the same name unless replace is true.",
        parameters: %{
          type: "object",
          properties: %{
            title: %{
              type: "string",
              description: "The recipe's name as the user says it, e.g. \"Grandma's Lasagna\"."
            },
            ingredients: %{
              type: "array",
              items: %{type: "string"},
              description:
                "Every ingredient with its quantity, one per item: [\"1 lb ground beef\", " <>
                  "\"12 lasagna noodles\"]."
            },
            steps: %{
              type: "array",
              items: %{type: "string"},
              description:
                "The method in order, one short action per item, unnumbered: [\"Preheat the " <>
                  "oven to 375°F.\", \"Bake 25 minutes.\"]."
            },
            servings: %{type: "string", description: "How many it serves, e.g. \"6\"."},
            notes: %{type: "string", description: "Tips or variations worth keeping."},
            source: %{
              type: "string",
              description: "Where it came from: a URL, a book, or a person (\"Grandma\")."
            },
            personal: %{
              type: "boolean",
              description:
                "true ONLY when the user asks to keep it private/just for them. Omit to share " <>
                  "it with the household (the default)."
            },
            replace: %{
              type: "boolean",
              description:
                "true to overwrite an existing recipe of the same name — only after the user " <>
                  "agreed to replace it."
            }
          },
          required: ["title", "ingredients", "steps"]
        }
      },
      %{
        name: "get_recipe",
        description:
          "Fetch a saved recipe: ingredients, numbered steps (each with any durations it " <>
            "names), servings, notes, source. Names match loosely (\"the lasagna\").",
        parameters: %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "Which recipe, e.g. \"lasagna\"."},
            personal: personal_param(),
            step: %{
              type: "integer",
              description:
                "COOK MODE only: the step number you are about to read aloud (1 to start, " <>
                  "+1 on \"next\", the same on \"repeat\"). Shows that step on their screen. " <>
                  "Omit when just looking the recipe up."
            }
          },
          required: ["name"]
        }
      },
      %{
        name: "list_recipes",
        description: "List the saved recipes the user can see, with counts.",
        parameters: %{type: "object", properties: %{}, required: []}
      },
      %{
        name: "edit_recipe",
        description:
          "Change a saved recipe in place: add or remove ingredients, replace the steps, " <>
            "replace or add to the notes, set servings or source. Returns the updated recipe.",
        parameters: %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "Which recipe, e.g. \"lasagna\"."},
            add_ingredients: %{
              type: "array",
              items: %{type: "string"},
              description: "Ingredients to append, with quantities: [\"3 cloves garlic\"]."
            },
            remove_ingredients: %{
              type: "array",
              items: %{type: "string"},
              description:
                "Ingredients to remove, as the user said them (\"the ricotta\") — matched by " <>
                  "words."
            },
            replace_steps: %{
              type: "array",
              items: %{type: "string"},
              description: "The COMPLETE new list of steps, in order (replaces all of them)."
            },
            notes: %{
              type: "string",
              description: "Replaces the recipe's notes entirely (\"\" clears them)."
            },
            add_note: %{
              type: "string",
              description: "A note to append to the existing notes (\"freezes well\")."
            },
            servings: %{type: "string", description: "New servings, e.g. \"8\"."},
            source: %{type: "string", description: "New source (URL or person)."},
            personal: personal_param()
          },
          required: ["name"]
        }
      },
      %{
        name: "delete_recipe",
        description: "Delete a saved recipe. Destructive — confirm with the user first.",
        parameters: %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "Which recipe to delete."},
            personal: personal_param()
          },
          required: ["name"]
        }
      }
    ]
  end

  defp personal_param do
    %{
      type: "boolean",
      description:
        "Only to pick between a private and a shared recipe of the same name: true = the " <>
          "user's private one, false = the household's. Usually omit."
    }
  end

  # --- execute ---------------------------------------------------------------------------------

  @impl true
  def execute(_name, _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — recipes unavailable, nothing saved"}}

  def execute("list_recipes", _args, %{user_id: uid}) do
    case Recipes.list(uid) do
      [] -> {:ok, %{recipes: [], note: "no recipes saved yet"}}
      recipes -> {:ok, %{count: length(recipes), recipes: Enum.map(recipes, &summary_view/1)}}
    end
  end

  def execute("save_recipe", %{"title" => title} = args, %{user_id: uid}) when is_binary(title) do
    household = args["personal"] != true

    case {Recipes.existing_for_save(uid, title, household), args["replace"] == true} do
      {%Recipes.Recipe{} = existing, false} ->
        {:ok,
         Map.merge(summary_view(existing), %{
           saved: false,
           exists: true,
           note:
             "a recipe called \"#{existing.title}\" is already saved — ask whether to " <>
               "replace it, then call save_recipe again with replace: true"
         })}

      _new_or_replace ->
        save(uid, args, household)
    end
  end

  def execute("get_recipe", %{"name" => name} = args, %{user_id: uid}) when is_binary(name) do
    case Recipes.get(uid, name, scope(args)) do
      {:ok, recipe} -> {:ok, recipe |> recipe_view() |> put_current_step(args["step"])}
      error -> miss(error, name, uid)
    end
  end

  def execute("edit_recipe", %{"name" => name} = args, %{user_id: uid}) when is_binary(name) do
    attrs =
      %{
        add_ingredients: args["add_ingredients"],
        remove_ingredients: args["remove_ingredients"],
        steps: args["replace_steps"],
        notes: string_or_nil(args["notes"]),
        add_note: string_or_nil(args["add_note"]),
        servings: string_or_nil(args["servings"]),
        source: string_or_nil(args["source"])
      }
      |> Map.reject(fn {_k, v} -> v == nil end)

    case Recipes.update(uid, name, attrs, scope(args)) do
      {:ok, recipe, report} ->
        {:ok,
         %{
           edited: true,
           added: report.added,
           already_listed: report.skipped,
           removed: report.removed,
           not_found: report.not_found,
           recipe: recipe_view(recipe)
         }}

      error ->
        miss(error, name, uid)
    end
  end

  def execute("delete_recipe", %{"name" => name} = args, %{user_id: uid}) when is_binary(name) do
    case Recipes.delete(uid, name, scope(args)) do
      {:ok, recipe} -> {:ok, %{deleted: recipe.title, personal: not recipe.household}}
      {:error, :not_found} -> {:ok, %{note: "no recipe called \"#{name}\" — nothing deleted"}}
      error -> miss(error, name, uid)
    end
  end

  def execute(name, _args, _ctx)
      when name in ~w(save_recipe get_recipe edit_recipe delete_recipe),
      do: {:error, :missing_args}

  def execute(_name, _args, _ctx), do: {:error, :unknown_tool}

  defp save(uid, args, household) do
    attrs = %{
      title: args["title"],
      ingredients: args["ingredients"],
      steps: args["steps"],
      servings: string_or_nil(args["servings"]),
      notes: string_or_nil(args["notes"]),
      source: string_or_nil(args["source"]),
      household: household
    }

    case Recipes.save(uid, attrs) do
      {:ok, recipe, how} ->
        {:ok,
         %{
           saved: true,
           replaced: how == :replaced,
           title: recipe.title,
           personal: not recipe.household,
           ingredient_count: length(recipe.ingredients),
           step_count: length(recipe.steps),
           # the saved recipe in get_recipe's shape, so it shows as a card (App.Cards)
           recipe: recipe_view(recipe)
         }}

      error ->
        miss(error, args["title"], uid)
    end
  end

  # A failed lookup/write → the brain-facing note (not found: what IS saved; ambiguous: which
  # ones to ask between) or a plain tool error.
  defp miss({:error, :not_found}, name, uid) do
    {:ok,
     %{
       note: "no recipe called \"#{name}\"",
       recipes: uid |> Recipes.list() |> Enum.map(& &1.title)
     }}
  end

  defp miss({:error, {:ambiguous, matches}}, name, _uid) do
    {:ok,
     %{
       note: "more than one recipe matches \"#{name}\" — ask which one",
       matches: Enum.map(matches, & &1.title)
     }}
  end

  defp miss({:error, {:which_scope, shared, _mine}}, _name, _uid) do
    {:ok,
     %{
       note:
         "there's a shared \"#{shared.title}\" AND a private one — ask which, then call again " <>
           "with personal: true for the private one or personal: false for the shared one"
     }}
  end

  defp miss({:error, %Ecto.Changeset{}}, _name, _uid), do: {:error, :invalid_recipe}
  defp miss({:error, _reason} = error, _name, _uid), do: error

  defp scope(%{"personal" => true}), do: :personal
  defp scope(%{"personal" => false}), do: :household
  defp scope(_args), do: :any

  # --- views -----------------------------------------------------------------------------------

  @doc false
  def recipe_view(recipe) do
    %{
      title: recipe.title,
      personal: not recipe.household,
      servings: recipe.servings,
      source: recipe.source,
      notes: recipe.notes,
      ingredient_count: length(recipe.ingredients),
      ingredients: recipe.ingredients,
      step_count: length(recipe.steps),
      steps:
        recipe.steps
        |> Enum.with_index(1)
        |> Enum.map(fn {text, n} -> %{number: n, text: text, durations: durations(text)} end)
    }
  end

  # Cook mode: the step the brain is about to read, clamped onto the recipe (a "next" past the
  # end stays on the last step). Anything that isn't a whole number is no step at all — the
  # plain recipe, with no cook-mode marker. App.Cards shows a marked result as that one step.
  defp put_current_step(%{step_count: count} = view, step) when count > 0 do
    case whole_number(step) do
      nil -> view
      n -> Map.put(view, :current_step, n |> max(1) |> min(count))
    end
  end

  defp put_current_step(view, _step), do: view

  defp whole_number(n) when is_integer(n), do: n
  defp whole_number(n) when is_float(n) and n == trunc(n), do: trunc(n)

  defp whole_number(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp whole_number(_), do: nil

  defp summary_view(recipe) do
    %{
      title: recipe.title,
      personal: not recipe.household,
      servings: recipe.servings,
      ingredient_count: length(recipe.ingredients),
      step_count: length(recipe.steps)
    }
  end

  @doc """
  Every duration a step names, as written ("25 to 30 minutes", "an hour", "1 1/2 hours",
  "10 min") — the cue for the brain to offer a timer. Digits (with fractions, decimals and
  ranges) or a spoken amount ("a", "an", "half an", "ten") before a seconds/minutes/hours unit.
  """
  def durations(text) when is_binary(text) do
    ~r/\b(?:\d+(?:\s+\d+\/\d+|\/\d+|[.,]\d+)?(?:\s*(?:-|–|to|or)\s*\d+(?:\s+\d+\/\d+|\/\d+|[.,]\d+)?)?\s*|(?:half\s+an?|an?|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty|thirty|forty-five|forty|sixty)\s+)(?:more\s+)?(?:seconds?|secs?|minutes?|mins?|hours?|hrs?)\b/iu
    |> Regex.scan(text)
    |> Enum.map(fn [match] -> String.trim(match) end)
  end

  defp string_or_nil(s) when is_binary(s), do: s
  defp string_or_nil(_), do: nil
end
