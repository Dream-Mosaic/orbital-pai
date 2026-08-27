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
end
