defmodule AppWeb.AmbientTest do
  use ExUnit.Case, async: true

  alias AppWeb.Ambient

  describe "weather_line/1" do
    test "renders temp_f + conditions" do
      assert Ambient.weather_line(%{current: %{temp_f: 72, conditions: "partly cloudy"}}) ==
               "72° partly cloudy"
    end

    test "is nil on the error result shape (no :current key)" do
      assert Ambient.weather_line(%{location: "Belleville, IL", error: "no data"}) == nil
    end

    test "is nil on nil" do
      assert Ambient.weather_line(nil) == nil
    end

    test "is nil on a map missing :current" do
      assert Ambient.weather_line(%{location: "Belleville, IL"}) == nil
    end
  end

  describe "next_event_line/2" do
    test "picks the first event at/after now, formatted in local time" do
      now = ~U[2026-07-05 14:00:00Z]

      events = [
        %{summary: "Standup", start: "2026-07-05T13:00:00Z", all_day?: false},
        %{summary: "Dinner", start: "2026-07-05T23:30:00Z", all_day?: false}
      ]

      assert Ambient.next_event_line(%{events: events}, now) == "Next: Dinner 6:30pm"
    end

    test "is nil on %{events: []}" do
      assert Ambient.next_event_line(%{events: []}, ~U[2026-07-05 14:00:00Z]) == nil
    end

    test "is nil on nil" do
      assert Ambient.next_event_line(nil, ~U[2026-07-05 14:00:00Z]) == nil
    end

    test "is nil on an error/missing shape (no :events key)" do
      assert Ambient.next_event_line(%{error: "boom"}, ~U[2026-07-05 14:00:00Z]) == nil
    end

    test "is nil when every event is already in the past" do
      now = ~U[2026-07-05 14:00:00Z]

      events = [
        %{summary: "Standup", start: "2026-07-05T13:00:00Z", all_day?: false},
        %{summary: "Coffee", start: "2026-07-05T13:30:00Z", all_day?: false}
      ]

      assert Ambient.next_event_line(%{events: events}, now) == nil
    end

    test "skips an all-day event (date-only start doesn't parse to a time)" do
      now = ~U[2026-07-05 14:00:00Z]

      events = [
        %{summary: "Company Holiday", start: "2026-07-05", all_day?: true},
        %{summary: "Dinner", start: "2026-07-05T23:30:00Z", all_day?: false}
      ]

      assert Ambient.next_event_line(%{events: events}, now) == "Next: Dinner 6:30pm"
    end

    test "an event exactly at now is still upcoming (not skipped)" do
      now = ~U[2026-07-05 23:30:00Z]

      events = [
        %{summary: "Dinner", start: "2026-07-05T23:30:00Z", all_day?: false}
      ]

      assert Ambient.next_event_line(%{events: events}, now) == "Next: Dinner 6:30pm"
    end
  end
end
