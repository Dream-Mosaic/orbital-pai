defmodule App.ListsTest do
  use App.DataCase, async: false
  alias App.Lists
  alias App.Lists.{List, Item}
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

  describe "schema" do
    test "a list can be created with user_id, household, and name", %{d: d} do
      {:ok, list} =
        %List{}
        |> List.changeset(%{user_id: d, name: "Groceries", household: true})
        |> Repo.insert()

      assert list.name == "Groceries"
      assert list.household == true
    end

    test "household defaults to false", %{d: d} do
      {:ok, list} = %List{} |> List.changeset(%{user_id: d, name: "To-do"}) |> Repo.insert()
      assert list.household == false
    end

    test "a list requires user_id and name" do
      assert {:error, cs} = %List{} |> List.changeset(%{}) |> Repo.insert()
      assert %{user_id: ["can't be blank"], name: ["can't be blank"]} = errors_on(cs)
    end

    test "an item can be created under a list, checked_at defaults to nil", %{d: d} do
      {:ok, list} = %List{} |> List.changeset(%{user_id: d, name: "To-do"}) |> Repo.insert()
      {:ok, item} = %Item{} |> Item.changeset(%{list_id: list.id, text: "milk"}) |> Repo.insert()

      assert item.text == "milk"
      assert item.checked_at == nil
    end

    test "an item requires list_id and text" do
      assert {:error, cs} = %Item{} |> Item.changeset(%{}) |> Repo.insert()
      assert %{list_id: ["can't be blank"], text: ["can't be blank"]} = errors_on(cs)
    end

    test "deleting a list deletes its items (FK cascade)", %{d: d} do
      {:ok, list} = %List{} |> List.changeset(%{user_id: d, name: "To-do"}) |> Repo.insert()
      {:ok, item} = %Item{} |> Item.changeset(%{list_id: list.id, text: "milk"}) |> Repo.insert()

      Repo.delete!(list)
      assert Repo.get(Item, item.id) == nil
    end
  end

  describe "find_or_create_list/2" do
    test "creates a new list when none matches", %{d: d} do
      list = Lists.find_or_create_list(%{user_id: d, household: false}, "Plants")
      assert list.name == "Plants"
      assert list.user_id == d
      assert list.household == false
    end

    test "finds an existing list case-insensitively instead of creating a duplicate", %{d: d} do
      {:ok, existing} =
        %List{}
        |> List.changeset(%{user_id: d, name: "Groceries", household: true})
        |> Repo.insert()

      found = Lists.find_or_create_list(%{user_id: d, household: true}, "groceries")
      assert found.id == existing.id
    end

    test "finds a list in the visible set (own + household), not another user's personal list", %{
      d: d,
      t: t
    } do
      {:ok, theirs} =
        %List{}
        |> List.changeset(%{user_id: t, name: "Groceries", household: false})
        |> Repo.insert()

      list = Lists.find_or_create_list(%{user_id: d, household: false}, "Groceries")
      refute list.id == theirs.id
    end

    test "a household match wins over a personal one when both exist", %{d: d} do
      {:ok, personal} =
        %List{}
        |> List.changeset(%{user_id: d, name: "Groceries", household: false})
        |> Repo.insert()

      {:ok, shared} =
        %List{}
        |> List.changeset(%{user_id: d, name: "Groceries", household: true})
        |> Repo.insert()

      found = Lists.find_or_create_list(%{user_id: d, household: true}, "Groceries")
      assert found.id == shared.id
      refute found.id == personal.id
    end

    test "a PERSONAL owner ('my X') resolves to the personal list, not a same-named household one",
         %{d: d} do
      {:ok, personal} =
        %List{}
        |> List.changeset(%{user_id: d, name: "Groceries", household: false})
        |> Repo.insert()

      {:ok, shared} =
        %List{}
        |> List.changeset(%{user_id: d, name: "Groceries", household: true})
        |> Repo.insert()

      # "add to my groceries" (household: false) must NOT get hijacked by the household list.
      found = Lists.find_or_create_list(%{user_id: d, household: false}, "Groceries")
      assert found.id == personal.id
      refute found.id == shared.id
    end
  end

  describe "list_visible/1" do
    test "returns the user's own + all household lists, not other users' personal", %{d: d, t: t} do
      {:ok, _mine} = %List{} |> List.changeset(%{user_id: d, name: "To-do"}) |> Repo.insert()
      {:ok, _theirs} = %List{} |> List.changeset(%{user_id: t, name: "Errands"}) |> Repo.insert()

      {:ok, _shared} =
        %List{}
        |> List.changeset(%{user_id: t, name: "Groceries", household: true})
        |> Repo.insert()

      names = Lists.list_visible(d) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["Groceries", "To-do"]
    end

    test "preloads each list's items", %{d: d} do
      {:ok, list} = %List{} |> List.changeset(%{user_id: d, name: "To-do"}) |> Repo.insert()
      {:ok, _item} = Lists.add_item(list, "call the plumber")

      [loaded] = Lists.list_visible(d)
      assert [%{text: "call the plumber"}] = loaded.items
    end
  end

  describe "add_item/2, check_item/1, uncheck_item/1" do
    test "adds an item and broadcasts on the owner's topic", %{d: d} do
      {:ok, list} = %List{} |> List.changeset(%{user_id: d, name: "To-do"}) |> Repo.insert()
      Phoenix.PubSub.subscribe(App.PubSub, "lists:#{d}")

      assert {:ok, item} = Lists.add_item(list, "milk")
      assert item.text == "milk"
      assert_receive {:lists_changed}
    end

    test "check_item stamps checked_at; uncheck_item clears it", %{d: d} do
      {:ok, list} = %List{} |> List.changeset(%{user_id: d, name: "Groceries"}) |> Repo.insert()
      {:ok, item} = Lists.add_item(list, "milk")

      assert {:ok, checked} = Lists.check_item(item)
      assert checked.checked_at != nil

      assert {:ok, unchecked} = Lists.uncheck_item(checked)
      assert unchecked.checked_at == nil
    end

    test "checking an item on a household list broadcasts on lists:household", %{d: d} do
      {:ok, list} =
        %List{}
        |> List.changeset(%{user_id: d, name: "Groceries", household: true})
        |> Repo.insert()

      {:ok, item} = Lists.add_item(list, "milk")

      Phoenix.PubSub.subscribe(App.PubSub, "lists:household")
      Lists.check_item(item)
      assert_receive {:lists_changed}
    end
  end

  describe "clear_checked/1" do
    test "deletes only the checked items on a list and reports the count", %{d: d} do
      {:ok, list} = %List{} |> List.changeset(%{user_id: d, name: "Groceries"}) |> Repo.insert()
      {:ok, done} = Lists.add_item(list, "milk")
      {:ok, _pending} = Lists.add_item(list, "eggs")
      {:ok, _} = Lists.check_item(done)

      assert Lists.clear_checked(list) == 1
      remaining = Repo.get!(List, list.id) |> Repo.preload(:items) |> Map.get(:items)
      assert Enum.map(remaining, & &1.text) == ["eggs"]
    end

    test "on a list with no checked items, returns 0", %{d: d} do
      {:ok, list} = %List{} |> List.changeset(%{user_id: d, name: "Groceries"}) |> Repo.insert()
      {:ok, _} = Lists.add_item(list, "eggs")
      assert Lists.clear_checked(list) == 0
    end
  end

  describe "remove_item/1 and delete_list/1" do
    test "remove_item deletes it and broadcasts", %{d: d} do
      {:ok, list} = %List{} |> List.changeset(%{user_id: d, name: "To-do"}) |> Repo.insert()
      {:ok, item} = Lists.add_item(list, "milk")

      assert {:ok, _} = Lists.remove_item(item)
      assert Repo.get(Item, item.id) == nil
    end

    test "delete_list removes the list and its items (FK cascade)", %{d: d} do
      {:ok, list} = %List{} |> List.changeset(%{user_id: d, name: "To-do"}) |> Repo.insert()
      {:ok, _item} = Lists.add_item(list, "milk")

      assert {:ok, _} = Lists.delete_list(list)
      assert Repo.get(List, list.id) == nil
      assert Repo.all(from i in Item, where: i.list_id == ^list.id) == []
    end
  end

  describe "find_item/2" do
    test "matches a phrase contained in an item's text, case-insensitively", %{d: d} do
      {:ok, list} = %List{} |> List.changeset(%{user_id: d, name: "Groceries"}) |> Repo.insert()
      {:ok, _} = Lists.add_item(list, "whole milk")

      found = Lists.find_item(list, "milk")
      assert found.text == "whole milk"
    end

    test "prefers an unchecked match over an already-checked one", %{d: d} do
      {:ok, list} = %List{} |> List.changeset(%{user_id: d, name: "Groceries"}) |> Repo.insert()
      {:ok, checked} = Lists.add_item(list, "milk")
      {:ok, _} = Lists.check_item(checked)
      {:ok, pending} = Lists.add_item(list, "milk")

      found = Lists.find_item(list, "milk")
      assert found.id == pending.id
    end

    test "nil for no match", %{d: d} do
      {:ok, list} = %List{} |> List.changeset(%{user_id: d, name: "Groceries"}) |> Repo.insert()
      assert Lists.find_item(list, "nonexistent") == nil
    end

    test "nil for a blank phrase", %{d: d} do
      {:ok, list} = %List{} |> List.changeset(%{user_id: d, name: "Groceries"}) |> Repo.insert()
      assert Lists.find_item(list, "") == nil
    end
  end
end
