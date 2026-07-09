defmodule App.Reminders.SchedulerTest do
  use App.DataCase, async: false
  alias App.Reminders
  alias App.Reminders.Scheduler
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "d@x.com", name: "Alice"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, u} = Users.upsert_allowed("d@x.com")
    %{user: u}
  end

  defp at(offset_s) do
    DateTime.utc_now() |> DateTime.add(offset_s, :second) |> DateTime.truncate(:second)
  end

  test "tick fires due reminders once, broadcasts them, skips future + already-fired", %{
    user: user
  } do
    Phoenix.PubSub.subscribe(App.PubSub, "reminders:#{user.id}")

    {:ok, _due} = Reminders.create(%{body: "call mom", due_at: at(-60), user_id: user.id})
    {:ok, _future} = Reminders.create(%{body: "later", due_at: at(3600), user_id: user.id})

    Scheduler.tick()

    assert_receive {:reminder_due, %{body: "call mom"}}, 1000
    refute_receive {:reminder_due, %{body: "later"}}, 200

    # the fired_at guard means a second tick does not re-broadcast
    Scheduler.tick()
    refute_receive {:reminder_due, _}, 200
  end

  test "firing broadcasts the UI message AND the agenda item", %{user: user} do
    Phoenix.PubSub.subscribe(App.PubSub, "reminders:#{user.id}")
    Phoenix.PubSub.subscribe(App.PubSub, "agenda:#{user.id}")

    {:ok, _r} =
      Reminders.create(%{
        user_id: user.id,
        body: "call mom",
        due_at: at(-60)
      })

    Scheduler.tick()

    assert_receive {:reminder_due, %App.Reminders.Reminder{body: "call mom"}}
    assert_receive {:agenda_due, %App.Agenda.Item{kind: :reminder} = item}
    assert item.prompt =~ "call mom"
  end
end
