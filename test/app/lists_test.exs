defmodule App.ListsTest do
  use App.DataCase, async: false
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
end
