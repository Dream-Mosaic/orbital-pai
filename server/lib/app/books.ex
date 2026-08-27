defmodule App.Books do
  @moduledoc """
  The "Books" nav seam: a unified, extensible abstraction over the household's collections — each
  of the user's visible LISTS (`App.Lists`) plus the singleton GARDEN (`App.Garden`) as peer
  "books" fronting the SAME existing panels. Adding a future hobby book type (3D printing,
  projects) is additive: one new `kind` + its enumerate/label/icon/clear arms here — no LiveView
  churn.

  A book is a lightweight descriptor `%{key, kind, id, label, icon, scope}` (no embedded data —
  callers resolve the actual list/garden content from their own already-loaded assigns, or via
  `App.Lists`/`App.Garden` directly):

    - `key` — the stable picker/pref id: `"list:<id>"` for a list book, `"garden"` for the garden.
    - `kind` — `:list` | `:garden`.
    - `id` — the underlying `App.Lists.List` id, or `nil` for the singleton garden book.
    - `label` — display name ("Groceries", "Garden", ...).
    - `icon` — a `hero-*` name, type-based for v1: a grocery/shopping-named list gets the cart, any
      other list gets the checklist, the garden gets the sun (matching its existing nav icon).
    - `scope` — `%{user_id, household}`: for a list book, that list's own owner scope; for the
      garden book, the CURRENT user's id (the garden itself has no single owner — see `clear/1`).
  """

  alias App.Repo
  alias App.Lists
  alias App.Lists.List
  alias App.Garden

  @doc """
  Every book `user` can see: their visible lists (`App.Lists.list_visible/1`, own + household) as
  `kind: :list` books, name-sorted, followed by the singleton `kind: :garden` book (always
  present, always last).
  """
  def for_user(user) do
    (user.id |> Lists.list_visible() |> Enum.map(&list_book/1)) ++ [garden_book(user)]
  end

  defp list_book(%List{} = list) do
    %{
      key: "list:#{list.id}",
      kind: :list,
      id: list.id,
      label: list.name,
      icon: list_icon(list.name),
      scope: %{user_id: list.user_id, household: list.household}
    }
  end

  defp garden_book(user) do
    %{
      key: "garden",
      kind: :garden,
      id: nil,
      label: "Garden",
      icon: "hero-sun",
      scope: %{user_id: user.id, household: false}
    }
  end

  defp list_icon(name) do
    down = String.downcase(name)

    if String.contains?(down, "grocer") or String.contains?(down, "shopping") do
      "hero-shopping-cart"
    else
      "hero-clipboard-document-list"
    end
  end

  @doc """
  Resolve a picker/pref `key` to a book in `user`'s visible set. `{:ok, book}`, or `:not_found`
  for a nil, blank, or stale key (e.g. a deleted list) — the caller falls back.
  """
  def resolve(nil, _user), do: :not_found

  def resolve(key, user) do
    case Enum.find(for_user(user), &(&1.key == key)) do
      nil -> :not_found
      book -> {:ok, book}
    end
  end

  @doc """
  `user`'s CURRENT book: their remembered pref (`user.books_last_book`) resolved against their
  visible set, or — for a nil, blank, or stale pref — the fallback priority: the household
  "groceries" list, THEN the first book, not merely the first book. `for_user/1` always appends
  the garden last, so with no list books at all "the first book" IS the garden — that's how
  "else Garden" is satisfied without a separate branch here.

  The single extraction point for this rule: it used to be copy-pasted between the web LiveView
  and the native panel's channel (independently, right down to the private `household_groceries?`
  helper), which is exactly the drift `AppWeb.BookFormat` exists to prevent for the panels'
  display strings — this closes the one function it stopped short of.
  """
  def current(user) do
    books = for_user(user)

    case user.books_last_book && Enum.find(books, &(&1.key == user.books_last_book)) do
      # `List` is aliased to `App.Lists.List` above — `Elixir.List` disambiguates the built-in.
      nil -> Enum.find(books, &household_groceries?/1) || Elixir.List.first(books)
      book -> book
    end
  end

  defp household_groceries?(%{kind: :list, label: label, scope: %{household: true}}),
    do: String.downcase(label) == "groceries"

  defp household_groceries?(_book), do: false

  @doc """
  Type-aware, non-destructive Clear: a `:list` book empties its items (`App.Lists.clear_items/1`
  — the list row itself stays); the `:garden` book closes out the season for BOTH the user's
  personal AND household active plants (`App.Garden.close_season/2` twice — the garden book is a
  single merged view with no one owner scope, so both are closed together, archiving everything
  the book currently shows). Returns `:ok`, or `{:error, :not_found}` if a list book's underlying
  list was already deleted elsewhere.
  """
  def clear(%{kind: :list, id: id}) do
    case Repo.get(List, id) do
      nil ->
        {:error, :not_found}

      list ->
        Lists.clear_items(list)
        :ok
    end
  end

  def clear(%{kind: :garden, scope: %{user_id: uid}}) do
    Garden.close_season(%{user_id: uid, household: false})
    Garden.close_season(%{user_id: uid, household: true})
    :ok
  end
end
