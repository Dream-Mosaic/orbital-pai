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
end
