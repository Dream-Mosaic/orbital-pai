defmodule App.Reminders.ReminderTest do
  use ExUnit.Case, async: true
  alias App.Reminders.Reminder

  test "changeset casts household and defaults it false" do
    base = %Reminder{}
    assert base.household == false

    cs =
      Reminder.changeset(base, %{
        user_id: 1,
        body: "bins",
        due_at: ~U[2026-07-11 18:00:00Z],
        household: true
      })

    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :household) == true
  end

  test "changeset casts a recurrence rule map and defaults it nil (one-shot)" do
    base = %Reminder{}
    assert base.recurrence == nil

    rule = %{"freq" => "weekly", "interval" => 1, "byday" => ["tue"]}

    cs =
      Reminder.changeset(base, %{
        user_id: 1,
        body: "bins",
        due_at: ~U[2026-07-14 14:00:00Z],
        recurrence: rule
      })

    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :recurrence) == rule
  end
end
