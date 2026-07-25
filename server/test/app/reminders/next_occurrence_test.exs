defmodule App.Reminders.NextOccurrenceTest do
  # Pure function — no DB, async: true. All expectations are America/Chicago local-time
  # facts converted to UTC by hand (CST = UTC-6, CDT = UTC-5; spring-forward 2026-03-08,
  # fall-back 2026-11-01).
  use ExUnit.Case, async: true

  alias App.Reminders

  @tz "America/Chicago"

  defp rule(freq, opts \\ []) do
    Enum.into(opts, %{"freq" => freq}, fn {k, v} -> {to_string(k), v} end)
  end

  describe "daily" do
    test "adds interval days, wall-clock preserved on a plain day" do
      # Tue Jul 14 09:00 CDT = 14:00Z; +3 days → Fri Jul 17 09:00 CDT
      assert Reminders.next_occurrence(
               ~U[2026-07-14 14:00:00Z],
               rule("daily", interval: 3),
               @tz
             ) == ~U[2026-07-17 14:00:00Z]
    end

    test "interval defaults to 1" do
      assert Reminders.next_occurrence(~U[2026-07-14 14:00:00Z], rule("daily"), @tz) ==
               ~U[2026-07-15 14:00:00Z]
    end

    test "8am stays 8am local across spring-forward (NOT +86400s)" do
      # Sat Mar 7 08:00 CST = 14:00Z → Sun Mar 8 08:00 CDT = 13:00Z
      assert Reminders.next_occurrence(~U[2026-03-07 14:00:00Z], rule("daily"), @tz) ==
               ~U[2026-03-08 13:00:00Z]
    end

    test "8am stays 8am local across fall-back" do
      # Sat Oct 31 08:00 CDT = 13:00Z → Sun Nov 1 08:00 CST = 14:00Z
      assert Reminders.next_occurrence(~U[2026-10-31 13:00:00Z], rule("daily"), @tz) ==
               ~U[2026-11-01 14:00:00Z]
    end

    test "spring-forward GAP (2:30am doesn't exist) lands just after the gap" do
      # Sat Mar 7 02:30 CST = 08:30Z → Sun Mar 8 02:30 doesn't exist → 03:00 CDT = 08:00Z
      assert Reminders.next_occurrence(~U[2026-03-07 08:30:00Z], rule("daily"), @tz) ==
               ~U[2026-03-08 08:00:00Z]
    end

    test "fall-back AMBIGUOUS wall time picks the earlier instant" do
      # Sat Oct 31 01:30 CDT = 06:30Z → Sun Nov 1 01:30 exists twice; earlier = CDT = 06:30Z
      assert Reminders.next_occurrence(~U[2026-10-31 06:30:00Z], rule("daily"), @tz) ==
               ~U[2026-11-01 06:30:00Z]
    end
  end

  describe "weekly" do
    # 2026-07-14 is a Tuesday; 09:00 CDT = 14:00Z throughout July.
    test "byday absent repeats on due_at's own weekday" do
      assert Reminders.next_occurrence(~U[2026-07-14 14:00:00Z], rule("weekly"), @tz) ==
               ~U[2026-07-21 14:00:00Z]
    end

    test "single byday, interval 1" do
      assert Reminders.next_occurrence(
               ~U[2026-07-14 14:00:00Z],
               rule("weekly", byday: ["tue"]),
               @tz
             ) == ~U[2026-07-21 14:00:00Z]
    end

    test "multi-day byday fires each listed day within the week" do
      r = rule("weekly", byday: ["tue", "thu"])
      # Tue Jul 14 → Thu Jul 16 (same week)
      assert Reminders.next_occurrence(~U[2026-07-14 14:00:00Z], r, @tz) ==
               ~U[2026-07-16 14:00:00Z]

      # Thu Jul 16 (last of cycle) → Tue Jul 21 (next week, interval 1)
      assert Reminders.next_occurrence(~U[2026-07-16 14:00:00Z], r, @tz) ==
               ~U[2026-07-21 14:00:00Z]
    end

    test "interval 2 steps two weeks between full cycles, but stays in-week mid-cycle" do
      r = rule("weekly", interval: 2, byday: ["tue", "thu"])
      # mid-cycle: Tue → Thu same week (interval applies only when the week rolls)
      assert Reminders.next_occurrence(~U[2026-07-14 14:00:00Z], r, @tz) ==
               ~U[2026-07-16 14:00:00Z]

      # cycle end: Thu Jul 16 → Tue Jul 28 (Monday of week+2 is Jul 27)
      assert Reminders.next_occurrence(~U[2026-07-16 14:00:00Z], r, @tz) ==
               ~U[2026-07-28 14:00:00Z]
    end

    test "due_at on a non-listed day steps to the next listed day" do
      # Wed Jul 15 with byday tue → Tue Jul 21 (next cycle's Tuesday)
      assert Reminders.next_occurrence(
               ~U[2026-07-15 14:00:00Z],
               rule("weekly", byday: ["tue"]),
               @tz
             ) == ~U[2026-07-21 14:00:00Z]
    end

    test "unknown byday codes are ignored (defensive; Task 6 filters at create)" do
      assert Reminders.next_occurrence(
               ~U[2026-07-14 14:00:00Z],
               rule("weekly", byday: ["bogus", "thu"]),
               @tz
             ) == ~U[2026-07-16 14:00:00Z]
    end
  end

  describe "monthly" do
    test "same day-of-month, mid-month, no clamp" do
      # Jul 15 09:00 CDT = 14:00Z → Aug 15 09:00 CDT
      assert Reminders.next_occurrence(~U[2026-07-15 14:00:00Z], rule("monthly"), @tz) ==
               ~U[2026-08-15 14:00:00Z]
    end

    test "interval 3 months" do
      assert Reminders.next_occurrence(
               ~U[2026-07-15 14:00:00Z],
               rule("monthly", interval: 3),
               @tz
             ) == ~U[2026-10-15 14:00:00Z]
    end

    test "end-of-month clamp chain: Jan 31 -> Feb 28 -> Mar 31 (2026, non-leap)" do
      r = rule("monthly")
      # Jan 31 09:00 CST = 15:00Z → Feb 28 09:00 CST = 15:00Z (clamped)
      assert Reminders.next_occurrence(~U[2026-01-31 15:00:00Z], r, @tz) ==
               ~U[2026-02-28 15:00:00Z]

      # Feb 28 (last day of Feb) → Mar 31 09:00 CDT = 14:00Z (end-of-month anchor restored;
      # UTC offset moves because March 31 is after spring-forward)
      assert Reminders.next_occurrence(~U[2026-02-28 15:00:00Z], r, @tz) ==
               ~U[2026-03-31 14:00:00Z]
    end

    test "leap year: Jan 31 2028 -> Feb 29 2028" do
      assert Reminders.next_occurrence(~U[2028-01-31 15:00:00Z], rule("monthly"), @tz) ==
               ~U[2028-02-29 15:00:00Z]
    end

    test "year rollover: Dec 15 -> Jan 15" do
      assert Reminders.next_occurrence(~U[2026-12-15 15:00:00Z], rule("monthly"), @tz) ==
               ~U[2027-01-15 15:00:00Z]
    end
  end

  describe "yearly" do
    test "same month+day next year" do
      # Jul 4 09:00 CDT = 14:00Z, both years
      assert Reminders.next_occurrence(~U[2026-07-04 14:00:00Z], rule("yearly"), @tz) ==
               ~U[2027-07-04 14:00:00Z]
    end

    test "interval 2 years" do
      assert Reminders.next_occurrence(
               ~U[2026-07-04 14:00:00Z],
               rule("yearly", interval: 2),
               @tz
             ) == ~U[2028-07-04 14:00:00Z]
    end

    test "Feb-29 clamps to Feb 28 in a non-leap year" do
      # Feb 29 2028 09:00 CST = 15:00Z → Feb 28 2029 09:00 CST
      assert Reminders.next_occurrence(~U[2028-02-29 15:00:00Z], rule("yearly"), @tz) ==
               ~U[2029-02-28 15:00:00Z]
    end
  end

  describe "until (inclusive end)" do
    test "next exactly ON until is still returned" do
      assert Reminders.next_occurrence(
               ~U[2026-07-14 14:00:00Z],
               rule("daily", until: "2026-07-15T14:00:00Z"),
               @tz
             ) == ~U[2026-07-15 14:00:00Z]
    end

    test "next after until -> nil (series exhausted)" do
      assert Reminders.next_occurrence(
               ~U[2026-07-14 14:00:00Z],
               rule("daily", until: "2026-07-14T20:00:00Z"),
               @tz
             ) == nil
    end
  end

  describe "count / remaining exhaustion" do
    test "remaining > 1 still advances" do
      assert %DateTime{} =
               Reminders.next_occurrence(
                 ~U[2026-07-14 14:00:00Z],
                 rule("daily", count: 3, remaining: 2),
                 @tz
               )
    end

    test "remaining <= 1 -> nil (this firing was the last)" do
      assert Reminders.next_occurrence(
               ~U[2026-07-14 14:00:00Z],
               rule("daily", count: 3, remaining: 1),
               @tz
             ) == nil
    end

    test "count without remaining seeds from count" do
      assert Reminders.next_occurrence(
               ~U[2026-07-14 14:00:00Z],
               rule("daily", count: 1),
               @tz
             ) == nil

      assert %DateTime{} =
               Reminders.next_occurrence(
                 ~U[2026-07-14 14:00:00Z],
                 rule("daily", count: 2),
                 @tz
               )
    end
  end

  describe "degenerate rules" do
    test "nil rule -> nil (a one-shot never advances)" do
      assert Reminders.next_occurrence(~U[2026-07-14 14:00:00Z], nil, @tz) == nil
    end

    test "unknown freq -> nil (defensive; Task 6 rejects at create)" do
      assert Reminders.next_occurrence(~U[2026-07-14 14:00:00Z], rule("hourly"), @tz) == nil
    end
  end
end
