defmodule App.Tools.RemindersTest do
  use App.DataCase, async: false
  alias App.Tools.Reminders, as: Tool
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "d@x.com", name: "Alice"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, u} = Users.upsert_allowed("d@x.com")
    %{user: u}
  end

  defp ctx(user),
    do: %{session_id: to_string(user.id), user_id: user.id, config: App.Config.default()}

  test "create_reminder stores the reminder and echoes it back", %{user: user} do
    due = "2030-01-01T17:00:00Z"

    assert {:ok, %{body: "call mom", due_at: ^due}} =
             Tool.execute("create_reminder", %{"body" => "call mom", "due_at" => due}, ctx(user))

    assert [%{body: "call mom"}] = App.Reminders.list_upcoming(user.id)
  end

  test "create_reminder rejects a non-ISO due_at", %{user: user} do
    assert {:error, :invalid_due_at} =
             Tool.execute("create_reminder", %{"body" => "x", "due_at" => "5pm-ish"}, ctx(user))
  end

  test "list_reminders returns upcoming reminders", %{user: user} do
    due = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    {:ok, _} = App.Reminders.create(%{body: "standup", due_at: due, user_id: user.id})

    assert {:ok, %{reminders: [%{body: "standup"}]}} =
             Tool.execute("list_reminders", %{}, ctx(user))
  end

  test "create_reminder with no user returns a narrated note, not a raw error" do
    assert {:ok, %{note: note}} =
             Tool.execute(
               "create_reminder",
               %{"body" => "x", "due_at" => "2030-01-01T17:00:00Z"},
               %{session_id: "default", user_id: nil, config: App.Config.default()}
             )

    assert note =~ "no user session"
  end

  test "list_reminders with no user returns an empty list" do
    assert {:ok, %{reminders: []}} =
             Tool.execute(
               "list_reminders",
               %{},
               %{session_id: "default", user_id: nil, config: App.Config.default()}
             )
  end

  test "list_reminders items include kind", %{user: user} do
    due = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    {:ok, _} = App.Reminders.create(%{body: "call mom", due_at: due, user_id: user.id})

    assert {:ok, %{reminders: [item]}} = Tool.execute("list_reminders", %{}, ctx(user))
    assert item.kind == "reminder"
  end

  describe "create_followup" do
    test "creates a followup-kind reminder with context", %{user: user} do
      assert {:ok, result} =
               Tool.execute(
                 "create_followup",
                 %{
                   "body" => "check whether Bob replied about the contract",
                   "due_at" => "2030-01-01T17:00:00Z",
                   "context" => "I'm emailing Bob about the contract"
                 },
                 ctx(user)
               )

      assert result.body == "check whether Bob replied about the contract"
      [r] = App.Reminders.list_upcoming(user.id)
      assert r.kind == "followup"
      assert r.context == "I'm emailing Bob about the contract"
    end

    test "context is optional", %{user: user} do
      assert {:ok, _} =
               Tool.execute(
                 "create_followup",
                 %{"body" => "check on the seedlings", "due_at" => "2030-01-01T17:00:00Z"},
                 ctx(user)
               )

      [r] = App.Reminders.list_upcoming(user.id)
      assert r.context == nil
    end

    test "bad due_at and nil user behave like create_reminder", %{user: user} do
      assert {:error, :invalid_due_at} =
               Tool.execute(
                 "create_followup",
                 %{"body" => "x", "due_at" => "tomorrow-ish"},
                 ctx(user)
               )

      assert {:ok, %{note: _}} =
               Tool.execute(
                 "create_followup",
                 %{"body" => "x", "due_at" => "2030-01-01T17:00:00Z"},
                 %{session_id: "default", user_id: nil, config: App.Config.default()}
               )
    end
  end

  describe "acknowledge_reminder" do
    defp past_due,
      do: DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

    test "acks the matching pending reminder", %{user: user} do
      {:ok, r} =
        App.Reminders.create(%{user_id: user.id, body: "take out the trash", due_at: past_due()})

      {:ok, _} = App.Reminders.mark_fired(r)

      assert {:ok, %{acknowledged: "take out the trash"}} =
               Tool.execute("acknowledge_reminder", %{"reminder" => "trash"}, ctx(user))

      assert App.Reminders.list_unacknowledged(user.id) == []
    end

    test "with no match returns a note, not an error", %{user: user} do
      assert {:ok, %{note: note}} =
               Tool.execute("acknowledge_reminder", %{"reminder" => "nope"}, ctx(user))

      assert note =~ "couldn't find"
    end

    test "with no user session returns a note, not an error" do
      assert {:ok, %{note: note}} =
               Tool.execute(
                 "acknowledge_reminder",
                 %{"reminder" => "trash"},
                 %{session_id: "default", user_id: nil, config: App.Config.default()}
               )

      assert note =~ "no user session"
    end
  end
end
