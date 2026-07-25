defmodule App.Reminders.NudgeTest do
  use ExUnit.Case, async: false
  alias App.Reminders.Nudge
  alias App.Reminders

  setup do
    App.DataCase.setup_sandbox(%{async: false})
    Application.put_env(:app, :allowed_users, [%{email: "alice@x.com", name: "Alice"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, alice} = App.Users.upsert_allowed("alice@x.com")
    %{uid: alice.id}
  end

  test "pull returns nil when nothing is pending", %{uid: uid} do
    assert Nudge.pull(to_string(uid)) == nil
  end

  test "pull returns a single agenda item naming the pending reminder(s)", %{uid: uid} do
    {:ok, r} =
      Reminders.create(%{
        user_id: uid,
        body: "take out the trash",
        due_at: ~U[2020-01-01 00:00:00Z]
      })

    {:ok, _} = Reminders.mark_fired(r)

    item = Nudge.pull(to_string(uid))
    assert %App.Agenda.Item{kind: :reminder, ack: nil, deliver: :when_idle} = item
    assert item.prompt =~ "take out the trash"
    assert item.prompt =~ "acknowledge_reminder"
  end

  test "pull ignores acknowledged reminders", %{uid: uid} do
    {:ok, r} =
      Reminders.create(%{user_id: uid, body: "call mom", due_at: ~U[2020-01-01 00:00:00Z]})

    {:ok, r} = Reminders.mark_fired(r)
    {:ok, _} = Reminders.acknowledge(r)
    assert Nudge.pull(to_string(uid)) == nil
  end

  test "a delivered recurring reminder never nudges (it advanced)", %{uid: uid} do
    {:ok, _r} =
      Reminders.create(%{
        user_id: uid,
        body: "water the tomatoes",
        due_at: ~U[2020-01-01 00:00:00Z],
        recurrence: %{"freq" => "daily", "interval" => 1}
      })

    App.Reminders.Scheduler.tick()

    assert Nudge.pull(to_string(uid)) == nil
  end
end
