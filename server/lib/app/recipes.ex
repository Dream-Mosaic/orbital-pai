defmodule App.Recipes do
  @moduledoc """
  The recipe book: saved recipes (ingredients + steps) that Henry can read back, push onto the
  groceries list, and walk through one step at a time in cook mode.

  HOUSEHOLD-SHARED BY DEFAULT, like lists: a recipe is visible to (and editable by) every
  member unless it was saved private (`household: false`), in which case only its owner ever
  sees it. Every read and write is scoped by the caller's visible set — own personal rows plus
  household rows — so one user can never reach another's private recipe.

  Names match loosely (`normalize/1`): case, punctuation, apostrophes, accents, a leading
  "the"/"my"/"our" and a trailing "recipe" are ignored, singular/plural collide, and a unique
  partial name ("the lasagna" → "Grandma's Lasagna", whole words only) finds it. When a partial
  name fits several recipes the lookup is `{:error, {:ambiguous, recipes}}` so the brain can
  ask which one. A personal recipe may share its name with a household one (a private variant
  of the house recipe): an unqualified lookup prefers the HOUSEHOLD one (shared-default, as
  with lists); pass the `:personal` scope to reach the private one.
  """
  import Ecto.Query
  alias App.Repo
  alias App.Recipes.Recipe

  @max_ingredient_length 300
  @max_step_length 1_000
  @articles ~w(the my our a an)

  @type scope :: :any | :household | :personal

  # ---------------------------------------------------------------------------------------------
  # Names

  @doc """
  The match key for a spoken recipe name, or nil when nothing is left: lowercased, accents
  folded, apostrophes dropped ("grandma's" → "grandmas"), other punctuation as spaces, a
  leading "the"/"my"/"our"/"a"/"an" and "recipe for" removed, and a trailing "recipe(s)"
  removed. Stored as `Recipe.name` (unique per owner scope).
  """
  def normalize(name) when is_binary(name) do
    case name |> words() |> drop_prefixes() |> drop_suffix() do
      [] -> nil
      words -> Enum.join(words, " ")
    end
  end

  def normalize(_), do: nil

  defp words(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace(~r/['’`]/u, "")
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
  end

  defp drop_prefixes([w | rest]) when w in @articles, do: drop_prefixes(rest)
  defp drop_prefixes(["recipe", w | rest]) when w in ~w(for of), do: drop_prefixes(rest)
  defp drop_prefixes(words), do: words

  defp drop_suffix(words) do
    if List.last(words) in ~w(recipe recipes), do: Enum.drop(words, -1), else: words
  end

  # Two words are the same up to a naive English plural: +s, +es, y ↔ ies.
  defp same_word?(a, b) do
    a == b or a <> "s" == b or b <> "s" == a or a <> "es" == b or b <> "es" == a or
      ies?(a, b) or ies?(b, a)
  end

  defp ies?(a, b), do: String.ends_with?(a, "y") and String.slice(a, 0..-2//1) <> "ies" == b

  defp same_words?(a, b) when length(a) == length(b),
    do: Enum.zip(a, b) |> Enum.all?(fn {x, y} -> same_word?(x, y) end)

  defp same_words?(_a, _b), do: false

  # `needle` appears in `haystack` as a contiguous run of (plural-insensitive) whole words.
  defp contains_words?(_haystack, []), do: false

  defp contains_words?(haystack, needle) do
    n = length(needle)

    n <= length(haystack) and
      Enum.any?(0..(length(haystack) - n)//1, fn i ->
        same_words?(Enum.slice(haystack, i, n), needle)
      end)
  end

  # ---------------------------------------------------------------------------------------------
  # Reads

  @doc "Every recipe `user_id` can see (own personal + household), ordered by name."
  def list(user_id) do
    Recipe
    |> scoped(user_id, :any)
    |> order_by([r], asc: r.name, asc: r.id)
    |> Repo.all()
  end

  @doc """
  The recipe `user_id` means by a spoken `name`, within `scope` (`:any` — own personal +
  household, the default; `:household`; `:personal` — the caller's own private ones).
  Tiers, first hit wins: exact key, then plural-insensitive key, then a whole-word partial
  match either way. Returns `{:ok, recipe}`, `{:error, :not_found}`, or
  `{:error, {:ambiguous, recipes}}` when a partial name fits several different recipes.
  """
  @spec get(integer(), String.t() | nil, scope()) ::
          {:ok, %Recipe{}} | {:error, :not_found} | {:error, {:ambiguous, [%Recipe{}]}}
  def get(user_id, name, scope \\ :any) do
    case normalize(name) do
      nil -> {:error, :not_found}
      key -> find(Recipe |> scoped(user_id, scope) |> Repo.all(), key)
    end
  end

  defp find(candidates, key) do
    words = String.split(key, " ")

    tiers = [
      &(&1.name == key),
      &same_words?(String.split(&1.name, " "), words),
      fn r ->
        name = String.split(r.name, " ")
        contains_words?(name, words) or contains_words?(words, name)
      end
    ]

    Enum.find_value(tiers, {:error, :not_found}, fn match? ->
      case Enum.filter(candidates, match?) do
        [] -> nil
        matches -> pick(matches)
      end
    end)
  end

  # Several matches of ONE name are the same recipe in both scopes (a personal variant of a
  # household recipe) — prefer the household one. Several different names are ambiguous.
  defp pick(matches) do
    case Enum.uniq_by(matches, & &1.name) do
      [_one_name] -> {:ok, Enum.max_by(matches, & &1.household)}
      distinct -> {:error, {:ambiguous, Enum.sort_by(distinct, & &1.name)}}
    end
  end

  defp scoped(query, uid, :any), do: where(query, [r], r.user_id == ^uid or r.household == true)
  defp scoped(query, _uid, :household), do: where(query, [r], r.household == true)

  defp scoped(query, uid, :personal),
    do: where(query, [r], r.household == false and r.user_id == ^uid)

  # ---------------------------------------------------------------------------------------------
  # Writes

  @doc """
  Create or REPLACE a recipe by name within its owner scope. `attrs` is ATOM-keyed: `title`,
  `ingredients` and `steps` (lists of strings) are required; `servings`, `notes`, `source`
  optional; `household` defaults to true (false = private to `user_id`). An existing recipe of
  the same (plural-insensitive) name IN THE SAME SCOPE is replaced wholesale — optional fields
  not given are cleared, and the original author stays the owner. A household save never
  touches a personal namesake, and vice versa.

  Items are cleaned: trimmed, blanks and non-strings dropped, leading bullets ("-", "•") and
  step numbers ("1.", "Step 2:") stripped — the tool numbers steps on the way out.

  Returns `{:ok, recipe, :created | :replaced}`, `{:error, :invalid_title}`,
  `{:error, :missing_ingredients}`, `{:error, :missing_steps}` or `{:error, changeset}`.
  """
  def save(user_id, attrs) do
    household = Map.get(attrs, :household, true) != false
    title = clean_title(attrs[:title])
    key = title && normalize(title)
    ingredients = clean_items(attrs[:ingredients], @max_ingredient_length)
    steps = attrs[:steps] |> clean_items(@max_step_length) |> Enum.map(&strip_number/1)

    cond do
      key == nil ->
        {:error, :invalid_title}

      ingredients == [] ->
        {:error, :missing_ingredients}

      steps == [] ->
        {:error, :missing_steps}

      true ->
        fields = %{
          title: title,
          name: key,
          ingredients: ingredients,
          steps: steps,
          servings: blank_nil(attrs[:servings]),
          notes: blank_nil(attrs[:notes]),
          source: blank_nil(attrs[:source])
        }

        upsert(existing(user_id, key, household), user_id, household, fields)
    end
  end

  defp upsert(nil, user_id, household, fields) do
    %Recipe{}
    |> Recipe.changeset(Map.merge(fields, %{user_id: user_id, household: household}))
    |> Repo.insert()
    |> tag(:created)
  end

  defp upsert(%Recipe{} = recipe, _user_id, _household, fields) do
    recipe |> Recipe.changeset(fields) |> Repo.update() |> tag(:replaced)
  end

  defp tag({:ok, recipe}, how), do: {:ok, broadcast_changed(recipe), how}
  defp tag(error, _how), do: error

  @doc """
  The recipe a `save/2` of `title` would REPLACE (same plural-insensitive name in the same
  owner scope), or nil when it would create a new one. The tool uses it to confirm before
  overwriting.
  """
  def existing_for_save(user_id, title, household) do
    case title |> clean_title() |> normalize() do
      nil -> nil
      key -> existing(user_id, key, household != false)
    end
  end

  defp existing(user_id, key, household) do
    words = String.split(key, " ")
    scope = if household, do: :household, else: :personal

    Recipe
    |> scoped(user_id, scope)
    |> order_by([r], asc: r.id)
    |> Repo.all()
    |> Enum.find(&(&1.name == key or same_words?(String.split(&1.name, " "), words)))
  end

  @doc """
  Edit a recipe the caller can see (`get/3` resolution, same `scope`). `attrs` is ATOM-keyed,
  all optional: `add_ingredients` (appended, case-insensitive duplicates skipped),
  `remove_ingredients` (spoken phrases — an exact ingredient match removes just that one, else
  every ingredient containing the phrase's words), `steps` (replaces them all), `notes`
  (replaces the notes), `add_note` (appended on a new line), `servings`, `source`.

  Returns `{:ok, recipe, %{added, skipped, removed, not_found}}`, `{:error, :nothing_to_change}`,
  `{:error, :missing_steps}` (a `steps` list that cleans to empty), or `get/3`'s errors.
  """
  def update(user_id, name, attrs, scope \\ :any) do
    with {:ok, recipe} <- get_for_write(user_id, name, scope),
         {:ok, changes, report} <- edits(recipe, attrs) do
      case recipe |> Recipe.changeset(changes) |> Repo.update() do
        {:ok, updated} -> {:ok, broadcast_changed(updated), report}
        error -> error
      end
    end
  end

  defp edits(recipe, attrs) do
    {ingredients, report} = edit_ingredients(recipe.ingredients, attrs)

    with {:ok, changes} <- edit_steps(%{}, attrs[:steps]) do
      changes =
        changes
        |> put_if(ingredients != recipe.ingredients, :ingredients, ingredients)
        |> put_present(attrs, :servings)
        |> put_present(attrs, :source)
        |> put_notes(recipe.notes, attrs)

      if changes == %{} and Enum.all?(Map.values(report), &(&1 == [])),
        do: {:error, :nothing_to_change},
        else: {:ok, changes, report}
    end
  end

  defp edit_steps(changes, nil), do: {:ok, changes}

  defp edit_steps(changes, steps) do
    case steps |> clean_items(@max_step_length) |> Enum.map(&strip_number/1) do
      [] -> {:error, :missing_steps}
      cleaned -> {:ok, Map.put(changes, :steps, cleaned)}
    end
  end

  defp edit_ingredients(current, attrs) do
    {kept, removed, not_found} =
      attrs[:remove_ingredients]
      |> clean_items(@max_ingredient_length)
      |> Enum.reduce({current, [], []}, fn phrase, {list, removed, missing} ->
        case matching_ingredients(list, phrase) do
          [] -> {list, removed, missing ++ [phrase]}
          hits -> {list -- hits, removed ++ hits, missing}
        end
      end)

    {final, added, skipped} =
      attrs[:add_ingredients]
      |> clean_items(@max_ingredient_length)
      |> Enum.reduce({kept, [], []}, fn item, {list, added, skipped} ->
        if Enum.any?(list, &(String.downcase(&1) == String.downcase(item))),
          do: {list, added, skipped ++ [item]},
          else: {list ++ [item], added ++ [item], skipped}
      end)

    {final, %{added: added, skipped: skipped, removed: removed, not_found: not_found}}
  end

  defp matching_ingredients(list, phrase) do
    exact = Enum.filter(list, &(String.downcase(&1) == String.downcase(phrase)))

    if exact != [] do
      exact
    else
      needle = phrase |> words() |> drop_prefixes()
      Enum.filter(list, &contains_words?(words(&1), needle))
    end
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp put_present(map, attrs, key) do
    if Map.has_key?(attrs, key) and attrs[key] != nil,
      do: Map.put(map, key, blank_nil(attrs[key])),
      else: map
  end

  # `notes` replaces the notes ("" clears them); `add_note` appends a line (to the replaced
  # notes when both are given).
  defp put_notes(map, current, attrs) do
    replace? = attrs[:notes] != nil
    base = if replace?, do: blank_nil(attrs[:notes]), else: current

    case {blank_nil(attrs[:add_note]), replace?} do
      {nil, false} -> map
      {nil, true} -> Map.put(map, :notes, base)
      {note, _} when base in [nil, ""] -> Map.put(map, :notes, note)
      {note, _} -> Map.put(map, :notes, base <> "\n" <> note)
    end
  end

  @doc "Delete a recipe the caller can see (`get/3` resolution). `{:ok, recipe}` or `get/3`'s errors."
  def delete(user_id, name, scope \\ :any) do
    with {:ok, recipe} <- get_for_write(user_id, name, scope),
         {:ok, deleted} <- Repo.delete(recipe),
         do: {:ok, broadcast_changed(deleted)}
  end

  @doc """
  Tell an open Books panel the recipe book changed; returns `recipe`. A household recipe
  notifies `"recipes:household"` (every member's panel shows it); a private one notifies only
  its owner's `"recipes:<user_id>"`, so the other person never learns it changed.
  """
  def broadcast_changed(%Recipe{household: true} = recipe) do
    Phoenix.PubSub.broadcast(App.PubSub, "recipes:household", {:recipes_changed})
    recipe
  end

  def broadcast_changed(%Recipe{user_id: uid} = recipe) do
    Phoenix.PubSub.broadcast(App.PubSub, "recipes:#{uid}", {:recipes_changed})
    recipe
  end

  # Reads may prefer the household copy when a name exists in both scopes; WRITES may not. "Delete
  # my lasagna recipe" with a shared Lasagna and a private one must not silently delete the shared
  # one (the speaker's "my" is stripped by normalization), so an unqualified write that resolves
  # in BOTH scopes asks which. An explicit scope (`personal: true/false`) goes straight through.
  defp get_for_write(user_id, name, :any) do
    with {:ok, recipe} <- get(user_id, name, :any) do
      case {get(user_id, name, :household), get(user_id, name, :personal)} do
        {{:ok, %{name: same} = shared}, {:ok, %{name: same} = mine}} ->
          {:error, {:which_scope, shared, mine}}

        _ ->
          {:ok, recipe}
      end
    end
  end

  defp get_for_write(user_id, name, scope), do: get(user_id, name, scope)

  # ---------------------------------------------------------------------------------------------
  # Cleaning

  defp clean_title(title) when is_binary(title) do
    cleaned =
      title
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.replace(~r/[.!?,;:]+$/u, "")
      |> String.replace(~r/\s+recipes?$/iu, "")
      |> String.trim()

    if cleaned == "", do: nil, else: cleaned
  end

  defp clean_title(_), do: nil

  defp clean_items(items, max) when is_list(items) do
    items
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.replace(~r/^[-*•·]\s+/u, "") |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.slice(&1, 0, max))
  end

  defp clean_items(_items, _max), do: []

  # "1. Mix" / "2) Fry" / "Step 3: Eat" / "Step 4 Serve" → the text alone. Not "1.5 hours…".
  defp strip_number(step) do
    case String.replace(step, ~r/^(?:step\s*\d+\s*[.):\-–]?|\d+\s*[.):\-–](?!\d))\s*/iu, "") do
      "" -> step
      stripped -> stripped
    end
  end

  defp blank_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_nil(_), do: nil
end
