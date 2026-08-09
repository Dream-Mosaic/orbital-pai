defmodule AppWeb.ReminderFormatTest do
  use ExUnit.Case, async: true
  alias AppWeb.ReminderFormat

  test "fmt_due renders in the configured timezone" do
    # America/Chicago is UTC-5 in July (CDT)
    assert ReminderFormat.fmt_due(~U[2026-07-05 23:30:00Z]) == "Jul 5 6:30pm"
  end

  describe "fmt_recurrence/2" do
    # 2026-07-14 14:00Z = Tue Jul 14, 9:00am CDT
    @due ~U[2026-07-14 14:00:00Z]

    test "nil rule (one-shot) -> nil" do
      assert ReminderFormat.fmt_recurrence(nil, @due) == nil
    end

    test "daily" do
      assert ReminderFormat.fmt_recurrence(%{"freq" => "daily"}, @due) == "daily"

      assert ReminderFormat.fmt_recurrence(%{"freq" => "daily", "interval" => 3}, @due) ==
               "every 3 days"
    end

    test "weekly: byday listed, or due_at's weekday when absent" do
      assert ReminderFormat.fmt_recurrence(%{"freq" => "weekly", "byday" => ["tue"]}, @due) ==
               "every Tue"

      assert ReminderFormat.fmt_recurrence(%{"freq" => "weekly", "byday" => ["tue", "thu"]}, @due) ==
               "every Tue, Thu"

      assert ReminderFormat.fmt_recurrence(%{"freq" => "weekly"}, @due) == "every Tue"

      assert ReminderFormat.fmt_recurrence(
               %{"freq" => "weekly", "interval" => 2, "byday" => ["mon"]},
               @due
             ) == "every 2 wks: Mon"
    end

    test "monthly names the local day-of-month" do
      # 2026-08-01 14:00Z = Aug 1, 9:00am CDT → day 1
      assert ReminderFormat.fmt_recurrence(%{"freq" => "monthly"}, ~U[2026-08-01 14:00:00Z]) ==
               "monthly on the 1st"

      assert ReminderFormat.fmt_recurrence(
               %{"freq" => "monthly", "interval" => 2},
               ~U[2026-07-15 14:00:00Z]
             ) == "every 2 months on the 15th"
    end

    test "yearly" do
      assert ReminderFormat.fmt_recurrence(%{"freq" => "yearly"}, @due) == "yearly"

      assert ReminderFormat.fmt_recurrence(%{"freq" => "yearly", "interval" => 2}, @due) ==
               "every 2 years"
    end
  end
end
