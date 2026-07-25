defmodule App.Tools.ListsTest do
  use App.DataCase, async: false
  alias App.Tools.Lists, as: Tool
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

  describe "add_to_list" do
    test "adds to the default To-do list when list is omitted, shared by default", %{user: user} do
      assert {:ok, result} =
               Tool.execute("add_to_list", %{"item" => "call the plumber"}, ctx(user))

      assert result.item == "call the plumber"
      assert result.list == "To-do"
      assert result.household == true
      assert result.assigned == "the household"
    end

    test "adds to a named book, creating it on demand", %{user: user} do
      assert {:ok, result} =
               Tool.execute(
                 "add_to_list",
                 %{"item" => "butter", "list" => "groceries"},
                 ctx(user)
               )

      assert result.list == "groceries"
      [list] = App.Lists.list_visible(user.id) |> Enum.filter(&(&1.name == "groceries"))
      assert Enum.map(list.items, & &1.text) == ["butter"]
    end

    test "for: my scopes it personal", %{user: user} do
      assert {:ok, result} =
               Tool.execute(
                 "add_to_list",
                 %{"item" => "call the plumber", "for" => "my"},
                 ctx(user)
               )

      assert result.household == false
      assert result.assigned == "you"
    end

    test "for: a named household member assigns it to them, when kiosk_user_switch is on", %{
      user: user,
      other: other
    } do
      Application.put_env(:app, :kiosk_user_switch, true)
      on_exit(fn -> Application.delete_env(:app, :kiosk_user_switch) end)

      assert {:ok, result} =
               Tool.execute("add_to_list", %{"item" => "milk", "for" => "bob"}, ctx(user))

      assert result.assigned == "Bob"
      assert Enum.any?(App.Lists.list_visible(other.id), &(&1.name == "To-do"))
    end

    test "for: a name falls back to personal when kiosk_user_switch is off (default)", %{
      user: user
    } do
      assert {:ok, result} =
               Tool.execute("add_to_list", %{"item" => "milk", "for" => "bob"}, ctx(user))

      assert result.assigned == "you"
      assert result.household == false
    end

    test "with no user session returns a narrated note" do
      assert {:ok, %{note: note}} = Tool.execute("add_to_list", %{"item" => "milk"}, no_session())
      assert note =~ "no user session"
    end
  end

  describe "check_off" do
    test "checks off a fuzzy-matched item", %{user: user} do
      {:ok, _} =
        Tool.execute("add_to_list", %{"item" => "whole milk", "list" => "groceries"}, ctx(user))

      assert {:ok, %{checked: "whole milk", list: "groceries"}} =
               Tool.execute("check_off", %{"item" => "milk", "list" => "groceries"}, ctx(user))
    end

    test "no match returns a benign note", %{user: user} do
      assert {:ok, %{note: note}} =
               Tool.execute("check_off", %{"item" => "nope", "list" => "groceries"}, ctx(user))

      assert note =~ "nothing to check off"
    end

    test "with no user session returns a note" do
      assert {:ok, %{note: note}} = Tool.execute("check_off", %{"item" => "milk"}, no_session())
      assert note =~ "no user session"
    end
  end

  describe "read_list" do
    test "reads back items, unchecked and checked", %{user: user} do
      {:ok, _} =
        Tool.execute("add_to_list", %{"item" => "milk", "list" => "groceries"}, ctx(user))

      {:ok, _} =
        Tool.execute("add_to_list", %{"item" => "eggs", "list" => "groceries"}, ctx(user))

      {:ok, _} = Tool.execute("check_off", %{"item" => "milk", "list" => "groceries"}, ctx(user))

      assert {:ok, %{list: "groceries", items: items}} =
               Tool.execute("read_list", %{"list" => "groceries"}, ctx(user))

      assert %{text: "milk", checked: true} in items
      assert %{text: "eggs", checked: false} in items
    end

    test "an empty (or not-yet-created) list reads back a benign note", %{user: user} do
      assert {:ok, %{items: [], note: note}} =
               Tool.execute("read_list", %{"list" => "plants"}, ctx(user))

      assert note =~ "nothing on"
    end

    test "with no user session returns a note" do
      assert {:ok, %{note: note}} = Tool.execute("read_list", %{}, no_session())
      assert note =~ "no user session"
    end
  end

  describe "clear_checked" do
    test "deletes the done items and reports the count", %{user: user} do
      {:ok, _} =
        Tool.execute("add_to_list", %{"item" => "milk", "list" => "groceries"}, ctx(user))

      {:ok, _} = Tool.execute("check_off", %{"item" => "milk", "list" => "groceries"}, ctx(user))

      assert {:ok, %{list: "groceries", cleared: 1}} =
               Tool.execute("clear_checked", %{"list" => "groceries"}, ctx(user))
    end

    test "with no user session returns a note" do
      assert {:ok, %{note: note}} = Tool.execute("clear_checked", %{}, no_session())
      assert note =~ "no user session"
    end
  end

  describe "remove_item" do
    test "removes a fuzzy-matched item entirely", %{user: user} do
      {:ok, _} =
        Tool.execute("add_to_list", %{"item" => "whole milk", "list" => "groceries"}, ctx(user))

      assert {:ok, %{removed: "whole milk", list: "groceries"}} =
               Tool.execute("remove_item", %{"item" => "milk", "list" => "groceries"}, ctx(user))
    end

    test "no match returns a benign note", %{user: user} do
      assert {:ok, %{note: note}} =
               Tool.execute("remove_item", %{"item" => "nope", "list" => "groceries"}, ctx(user))

      assert note =~ "nothing to remove"
    end

    test "with no user session returns a note" do
      assert {:ok, %{note: note}} = Tool.execute("remove_item", %{"item" => "milk"}, no_session())
      assert note =~ "no user session"
    end
  end
end
