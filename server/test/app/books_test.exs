defmodule App.BooksTest do
  use App.DataCase, async: false
  alias App.{Books, Lists, Garden, Users}
  alias App.Lists.List

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "d@x.com", name: "Alice"},
      %{email: "t@x.com", name: "Bob"}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, d} = Users.upsert_allowed("d@x.com")
    {:ok, t} = Users.upsert_allowed("t@x.com")
    %{d: d, t: t}
  end

  describe "for_user/1" do
    test "lists the user's visible lists as :list books, name-sorted, then the singleton garden book",
         %{d: d} do
      {:ok, groceries} =
        %List{}
        |> List.changeset(%{user_id: d.id, name: "Groceries", household: true})
        |> Repo.insert()

      {:ok, todo} =
        %List{}
        |> List.changeset(%{user_id: d.id, name: "To-do", household: false})
        |> Repo.insert()

      books = Books.for_user(d)

      assert Enum.map(books, & &1.key) == ["list:#{groceries.id}", "list:#{todo.id}", "garden"]
      assert Enum.map(books, & &1.kind) == [:list, :list, :garden]
      assert Enum.map(books, & &1.label) == ["Groceries", "To-do", "Garden"]
    end

    test "a grocery/shopping-named list gets the cart icon; any other list gets the checklist icon; garden gets the sun",
         %{d: d} do
      {:ok, _} = %List{} |> List.changeset(%{user_id: d.id, name: "Groceries"}) |> Repo.insert()
      {:ok, _} = %List{} |> List.changeset(%{user_id: d.id, name: "Hardware"}) |> Repo.insert()

      [groceries, hardware, garden] = Books.for_user(d)

      assert groceries.icon == "hero-shopping-cart"
      assert hardware.icon == "hero-clipboard-document-list"
      assert garden.icon == "hero-sun"
    end

    test "with no lists, returns just the garden book", %{d: d} do
      assert [%{key: "garden", kind: :garden, id: nil}] = Books.for_user(d)
    end

    test "does not include another user's personal lists", %{d: d, t: t} do
      {:ok, _theirs} =
        %List{} |> List.changeset(%{user_id: t.id, name: "Errands"}) |> Repo.insert()

      assert Books.for_user(d) |> Enum.map(& &1.label) == ["Garden"]
    end
  end

  describe "resolve/2" do
    test "round-trips a list book's key", %{d: d} do
      {:ok, list} =
        %List{} |> List.changeset(%{user_id: d.id, name: "Groceries"}) |> Repo.insert()

      assert {:ok, book} = Books.resolve("list:#{list.id}", d)
      assert book.id == list.id
      assert book.kind == :list
    end

    test "round-trips the garden key", %{d: d} do
      assert {:ok, %{kind: :garden}} = Books.resolve("garden", d)
    end

    test "returns :not_found for a stale, missing, or nil key", %{d: d} do
      assert Books.resolve("list:999999", d) == :not_found
      assert Books.resolve("bogus", d) == :not_found
      assert Books.resolve(nil, d) == :not_found
    end
  end

  describe "current/1" do
    test "the pref, when it resolves, wins outright — not merely the fallback priority", %{d: d} do
      {:ok, _apples} =
        %List{} |> List.changeset(%{user_id: d.id, name: "Apples"}) |> Repo.insert()

      {:ok, zebra} = %List{} |> List.changeset(%{user_id: d.id, name: "Zebra"}) |> Repo.insert()
      {:ok, d} = Users.update_prefs(d, %{books_last_book: "list:#{zebra.id}"})

      # If the pref were ignored, the fallback (no household groceries here) would land on
      # "Apples" (first by name) — the pref must win over that.
      assert Books.current(d).id == zebra.id
    end

    test "a stale or nil pref falls back to the HOUSEHOLD groceries list, not merely the first book",
         %{d: d} do
      # "Apples" sorts before "Groceries", so the two candidate answers DISAGREE: a fixture where
      # groceries also happened to be first alphabetically would let `List.first/1` pass by luck.
      {:ok, _apples} =
        %List{} |> List.changeset(%{user_id: d.id, name: "Apples"}) |> Repo.insert()

      {:ok, groceries} =
        %List{}
        |> List.changeset(%{user_id: d.id, name: "Groceries", household: true})
        |> Repo.insert()

      {:ok, d} = Users.update_prefs(d, %{books_last_book: "list:999999"})

      current = Books.current(d)
      assert current.id == groceries.id
      refute current.label == "Apples"
    end

    test "with no household groceries list, a stale or nil pref falls back to the first book",
         %{d: d} do
      {:ok, apples} = %List{} |> List.changeset(%{user_id: d.id, name: "Apples"}) |> Repo.insert()
      {:ok, _zebra} = %List{} |> List.changeset(%{user_id: d.id, name: "Zebra"}) |> Repo.insert()

      assert Books.current(d).id == apples.id
    end

    test "with no lists at all, a nil pref falls back to the garden book", %{d: d} do
      assert Books.current(d).kind == :garden
    end
  end

  describe "clear/1" do
    test "for a :list book, empties the list's items and keeps the list", %{d: d} do
      {:ok, list} =
        %List{} |> List.changeset(%{user_id: d.id, name: "Groceries"}) |> Repo.insert()

      {:ok, _} = Lists.add_item(list, "milk")

      {:ok, book} = Books.resolve("list:#{list.id}", d)
      assert Books.clear(book) == :ok

      reloaded = Lists.with_items(list)
      assert reloaded.items == []
      assert Repo.get(List, list.id) != nil
    end

    test "for the :garden book, closes out BOTH the user's personal and household seasons", %{
      d: d
    } do
      {:ok, _} = Garden.add_plant(%{user_id: d.id, household: false}, %{name: "my herbs"})
      {:ok, _} = Garden.add_plant(%{user_id: d.id, household: true}, %{name: "tomatoes"})

      {:ok, book} = Books.resolve("garden", d)
      assert Books.clear(book) == :ok

      assert Garden.garden(d.id).active == []
    end

    test "for a :list book whose underlying list was deleted elsewhere, returns {:error, :not_found}",
         %{d: d} do
      {:ok, list} =
        %List{} |> List.changeset(%{user_id: d.id, name: "Groceries"}) |> Repo.insert()

      {:ok, book} = Books.resolve("list:#{list.id}", d)
      Repo.delete!(list)

      assert Books.clear(book) == {:error, :not_found}
    end
  end

  describe "the shelf (collections after the garden)" do
    test "shelf/1 is for_user/1 followed by recipes, trackers and routines", %{d: d} do
      {:ok, _} = %List{} |> List.changeset(%{user_id: d.id, name: "Groceries"}) |> Repo.insert()

      assert Enum.map(Books.shelf(d), & &1.key) ==
               Enum.map(Books.for_user(d), & &1.key) ++ ["recipes", "trackers", "routines"]

      assert Enum.map(Books.collections(), & &1.kind) == [:recipes, :trackers, :routines]

      assert Enum.map(Books.collections(), & &1.icon) == [
               "hero-cake",
               "hero-chart-bar",
               "hero-bolt"
             ]
    end

    test "for_user/1 stays lists + garden: the web dashboard has no body for a collection",
         %{d: d} do
      assert Enum.map(Books.for_user(d), & &1.kind) == [:garden]
    end

    test "resolve_on_shelf/2 resolves a collection key, then anything resolve/2 does", %{d: d} do
      {:ok, list} = %List{} |> List.changeset(%{user_id: d.id, name: "Errands"}) |> Repo.insert()

      assert {:ok, %{kind: :recipes}} = Books.resolve_on_shelf("recipes", d)
      assert {:ok, %{kind: :routines}} = Books.resolve_on_shelf("routines", d)
      assert {:ok, %{id: id}} = Books.resolve_on_shelf("list:#{list.id}", d)
      assert id == list.id
      assert Books.resolve_on_shelf("bogus", d) == :not_found
      assert Books.resolve_on_shelf(nil, d) == :not_found
      # resolve/2 itself is untouched: the web can't land on a collection.
      assert Books.resolve("recipes", d) == :not_found
    end

    test "current_on_shelf/1 honours a remembered collection; current/1 falls back past it",
         %{d: d} do
      {:ok, groceries} =
        %List{}
        |> List.changeset(%{user_id: d.id, name: "Groceries", household: true})
        |> Repo.insert()

      {:ok, d} = Users.update_prefs(d, %{books_last_book: "trackers"})

      assert Books.current_on_shelf(d).kind == :trackers
      # The web reads the same pref through current/1 and lands on its usual fallback.
      assert Books.current(d).id == groceries.id
    end

    test "current_on_shelf/1 is current/1 exactly for anything that is not a collection",
         %{d: d} do
      {:ok, list} = %List{} |> List.changeset(%{user_id: d.id, name: "Errands"}) |> Repo.insert()
      {:ok, d} = Users.update_prefs(d, %{books_last_book: "list:#{list.id}"})
      assert Books.current_on_shelf(d) == Books.current(d)

      {:ok, d} = Users.update_prefs(d, %{books_last_book: "list:999999"})
      assert Books.current_on_shelf(d) == Books.current(d)
    end

    test "a collection is never clearable" do
      for book <- Books.collections() do
        assert Books.clear(book) == {:error, :not_clearable}
      end
    end
  end
end
