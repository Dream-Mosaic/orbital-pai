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

  describe "recurrence" do
    defp daily_rule(remaining \\ nil) do
      base = %{"freq" => "daily", "interval" => 1}

      if remaining,
        do: Map.merge(base, %{"count" => remaining, "remaining" => remaining}),
        else: base
    end

    test "a recurring reminder fires once, delivers, and the SAME row re-schedules", %{user: user} do
      Phoenix.PubSub.subscribe(App.PubSub, "reminders:#{user.id}")
      Phoenix.PubSub.subscribe(App.PubSub, "agenda:#{user.id}")

      {:ok, r} =
        Reminders.create(%{
          user_id: user.id,
          body: "water the tomatoes",
          due_at: at(-60),
          recurrence: daily_rule()
        })

      Scheduler.tick()

      # this occurrence fired + was handed to delivery
      assert_receive {:reminder_due, %{body: "water the tomatoes"}}, 1000
      assert_receive {:agenda_due, %App.Agenda.Item{kind: :reminder}}, 1000

      # ...and the row advanced: back to scheduled, next occurrence in the future
      reloaded = App.Repo.reload!(r)
      assert reloaded.fired_at == nil

      assert reloaded.due_at ==
               Reminders.next_occurrence(r.due_at, r.recurrence, App.Config.timezone())

      assert DateTime.compare(reloaded.due_at, DateTime.utc_now()) == :gt

      # exactly-once: a second tick does NOT re-fire this occurrence
      Scheduler.tick()
      refute_receive {:reminder_due, _}, 200

      # ...but the next occurrence IS in the schedule for when its time comes
      due_then = Reminders.due_now(DateTime.add(reloaded.due_at, 60, :second))
      assert Enum.any?(due_then, &(&1.id == r.id))
    end

    test "a delivered recurring reminder never becomes pending (no nudge loop), even after the late ack MFA runs",
         %{user: user} do
      Phoenix.PubSub.subscribe(App.PubSub, "agenda:#{user.id}")

      {:ok, _r} =
        Reminders.create(%{
          user_id: user.id,
          body: "stretch",
          due_at: at(-60),
          recurrence: daily_rule()
        })

      Scheduler.tick()
      assert_receive {:agenda_due, %App.Agenda.Item{ack: {mod, fun, args}}}, 1000

      # The Conversation invokes the item's ack (mark_delivered) AFTER speaking — i.e. after the
      # advance. Replaying it on the stale struct must not resurrect a pending state.
      apply(mod, fun, args)

      assert Reminders.list_unacknowledged(user.id) == []
    end

    test "series-complete: the last occurrence fires, the row stays fired and drops out", %{
      user: user
    } do
      Phoenix.PubSub.subscribe(App.PubSub, "reminders:#{user.id}")

      {:ok, r} =
        Reminders.create(%{
          user_id: user.id,
          body: "final call",
          due_at: at(-60),
          recurrence: daily_rule(1)
        })

      Scheduler.tick()
      assert_receive {:reminder_due, %{body: "final call"}}, 1000

      reloaded = App.Repo.reload!(r)
      assert reloaded.fired_at != nil
      assert reloaded.due_at == r.due_at

      Scheduler.tick()
      refute_receive {:reminder_due, _}, 200
    end

    test "additive invariant: a one-shot still stays fired + pending after the tick", %{
      user: user
    } do
      {:ok, r} = Reminders.create(%{user_id: user.id, body: "one-shot", due_at: at(-60)})

      Scheduler.tick()

      reloaded = App.Repo.reload!(r)
      assert reloaded.fired_at != nil
      assert reloaded.due_at == r.due_at
      assert Enum.any?(Reminders.list_unacknowledged(user.id), &(&1.id == r.id))
    end
  end
end
