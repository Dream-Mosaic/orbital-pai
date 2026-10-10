defmodule AppWeb.CollectionFormatTest do
  use ExUnit.Case, async: true

  alias AppWeb.CollectionFormat, as: F
  alias App.Recipes.Recipe
  alias App.Routines.Routine
  alias App.Trackers.{Entry, Tracker}

  @tz "America/Chicago"
  # Sat Oct 10 2026, 3:00 PM in Chicago (CDT, UTC-5).
  @now ~U[2026-10-10 20:00:00Z]

  defp recipe(attrs) do
    struct(
      %Recipe{
        id: 1,
        user_id: 1,
        household: true,
        name: "lasagna",
        title: "Lasagna",
        ingredients: ["1 lb ground beef", "12 noodles", "ricotta"],
        steps: ["Layer.", "Bake."]
      },
      attrs
    )
  end

  # `local` is a Chicago wall-clock NaiveDateTime.
  defp entry(local, attrs \\ %{}) do
    at = local |> DateTime.from_naive!(@tz) |> DateTime.shift_zone!("Etc/UTC")
    struct(%Entry{id: System.unique_integer([:positive]), recorded_at: at, tags: []}, attrs)
  end

  defp tracker_row(entries, attrs \\ %{}) do
    t = struct(%Tracker{id: 7, user_id: 1, name: "headache", label: "headaches"}, attrs)
    %{tracker: t, count: length(entries), last_entry: List.first(entries)}
  end

  describe "recipes" do
    test "a shared recipe row: title, tag, counts, the full body and its own delete copy" do
      row =
        F.recipe(
          recipe(title: "Grandma's Lasagna", servings: "6", source: "Grandma", notes: "Rest it.")
        )

      assert row.id == 1
      assert row.title == "Grandma's Lasagna"
      assert row.shared == true
      assert row.tag == "shared"
      assert row.meta == "3 ingredients · 2 steps"
      assert row.detail_meta == "Serves 6 · From Grandma"
      assert row.ingredients == ["1 lb ground beef", "12 noodles", "ricotta"]
      assert row.steps == ["Layer.", "Bake."]
      assert row.notes == "Rest it."

      assert row.delete_confirm ==
               "Delete “Grandma's Lasagna” from the shared recipe book? It goes for everyone, and can't be undone."
    end

    test "a private recipe is tagged yours and confirms as yours" do
      row = F.recipe(recipe(household: false, ingredients: ["salt"], steps: ["Eat."]))

      assert row.tag == "yours"
      assert row.shared == false
      assert row.meta == "1 ingredient · 1 step"
      assert row.detail_meta == nil
      assert row.notes == nil
      assert row.delete_confirm == "Delete your recipe “Lasagna”? This can't be undone."
    end

    test "servings read naturally whatever shape they were said in" do
      meta = fn s -> F.recipe(recipe(servings: s)).detail_meta end

      assert meta.("4") == "Serves 4"
      assert meta.("4-6") == "Serves 4-6"
      assert meta.("6 people") == "Serves 6 people"
      assert meta.("makes 24 cookies") == "Makes 24 cookies"
      assert meta.("Serves 8") == "Serves 8"
    end

    test "a URL source shows just its host" do
      row = F.recipe(recipe(source: "https://www.seriouseats.com/the-best-lasagna"))
      assert row.detail_meta == "From seriouseats.com"
    end

    test "the body carries its own empty-state copy" do
      body = F.recipes([])
      assert body.items == []
      assert body.empty == "No recipes yet."
      assert body.hint == "Try: “Henry, save my lasagna recipe…”"
    end
  end

  describe "trackers" do
    test "the list row: a capitalised label, the unit, the count and the last entry" do
      es = [entry(~N[2026-10-08 09:00:00], %{value: 6.0})]
      row = F.tracker(tracker_row(es, unit: "pain 1-10"), es, @now, @tz)

      assert row.id == 7
      assert row.label == "Headaches"
      assert row.unit == "pain 1-10"
      assert row.count == "1 entry"
      assert row.last == "2 days ago · 6"
    end

    test "last entry: today, yesterday, days ago, then a date; a short unit rides the value" do
      last = fn local, extra ->
        es = [entry(local, extra)]
        F.tracker(tracker_row(es, unit: "lb"), es, @now, @tz).last
      end

      assert last.(~N[2026-10-10 08:00:00], %{value: 182.4}) == "Today · 182.4 lb"
      assert last.(~N[2026-10-09 23:30:00], %{}) == "Yesterday"
      assert last.(~N[2026-09-28 12:00:00], %{value: 181.0}) == "12 days ago · 181 lb"
      assert last.(~N[2026-09-20 12:00:00], %{}) == "Sep 20"
      assert last.(~N[2025-12-31 12:00:00], %{}) == "Dec 31, 2025"
    end

    test "an empty tracker says so" do
      row = F.tracker(tracker_row([]), [], @now, @tz)
      assert row.count == "0 entries"
      assert row.last == "No entries yet"
      assert row.stats == []
      assert row.recent == []
      assert row.quiet == "Nothing logged in the last 30 days."
    end

    test "the detail: 30 days oldest-first, each day's worst value, the peak marked" do
      es = [
        entry(~N[2026-10-10 08:00:00], %{value: 4.0}),
        entry(~N[2026-10-08 18:00:00], %{value: 8.0}),
        entry(~N[2026-10-08 09:00:00], %{value: 3.0}),
        # Outside the window: counted nowhere in the chart or the stats.
        entry(~N[2026-08-01 09:00:00], %{value: 10.0})
      ]

      row = F.tracker(tracker_row(es), es, @now, @tz)

      assert row.range == "Last 30 days"
      assert length(row.series) == 30
      assert hd(row.series).label == "Sep 11"
      assert List.last(row.series).label == "Oct 10"
      assert row.axis_from == "Sep 11"
      assert row.axis_to == "Today"

      oct8 = Enum.at(row.series, 27)

      assert oct8 == %{
               label: "Oct 8",
               count: 2,
               value: 8,
               peak: "8",
               tip: "Thu, Oct 8 · up to 8 · 2 entries"
             }

      assert List.last(row.series) ==
               %{label: "Oct 10", count: 1, value: 4, peak: nil, tip: "Today · 4"}

      assert Enum.at(row.series, 28) ==
               %{
                 label: "Oct 9",
                 count: 0,
                 value: nil,
                 peak: nil,
                 tip: "Yesterday · Nothing logged"
               }

      assert row.stats == [
               %{label: "Average", value: "5"},
               %{label: "Range", value: "3–8"},
               %{label: "Entries", value: "3"}
             ]

      assert row.quiet == nil
    end

    test "a habit tracker (no values) headlines entries, days and its best streak" do
      es = [
        entry(~N[2026-10-10 08:00:00]),
        entry(~N[2026-10-09 08:00:00]),
        entry(~N[2026-10-09 20:00:00]),
        entry(~N[2026-10-08 08:00:00])
      ]

      row = F.tracker(tracker_row(es, label: "no soda"), es, @now, @tz)

      assert row.label == "No soda"

      assert row.stats == [
               %{label: "Entries", value: "4"},
               %{label: "Days", value: "3"},
               %{label: "Best streak", value: "3 days"}
             ]

      assert Enum.at(row.series, 28) ==
               %{label: "Oct 9", count: 2, value: nil, peak: nil, tip: "Yesterday · 2 entries"}

      assert Enum.at(row.series, 27).tip == "Thu, Oct 8 · 1 entry"
    end

    test "a single valued entry's tip carries a short unit" do
      es = [entry(~N[2026-10-07 08:00:00], %{value: 182.4})]
      row = F.tracker(tracker_row(es, unit: "lb"), es, @now, @tz)
      assert Enum.at(row.series, 26).tip == "Wed, Oct 7 · 182.4 lb"
    end

    test "top tags carry a tally only when it is more than one" do
      es = [
        entry(~N[2026-10-10 08:00:00], %{tags: ["skipped lunch", "poor sleep"]}),
        entry(~N[2026-10-09 08:00:00], %{tags: ["skipped lunch"]})
      ]

      row = F.tracker(tracker_row(es), es, @now, @tz)

      assert row.tags == [
               %{tag: "skipped lunch", tally: "×2"},
               %{tag: "poor sleep", tally: nil}
             ]
    end

    test "recent entries: newest first, day + clock, value, note, tags; capped at 20" do
      es =
        for d <- 0..24 do
          entry(NaiveDateTime.add(~N[2026-10-10 14:15:00], -d * 86_400), %{
            value: 5.0,
            note: if(d == 0, do: "after lunch"),
            tags: if(d == 0, do: ["stress"], else: [])
          })
        end

      row = F.tracker(tracker_row(es), es, @now, @tz)

      assert length(row.recent) == 20
      assert row.more == "Showing the latest 20 of 25"

      assert hd(row.recent) == %{
               day: "Today",
               time: "2:15 PM",
               value: "5",
               note: "after lunch",
               tags: ["stress"]
             }

      assert Enum.at(row.recent, 1).day == "Yesterday"

      assert Enum.at(row.recent, 3) == %{
               day: "Wed, Oct 7",
               time: "2:15 PM",
               value: "5",
               note: nil,
               tags: []
             }
    end

    test "a scale unit (with a number in it) does not ride the value" do
      es = [entry(~N[2026-10-10 08:00:00], %{value: 6.5})]
      row = F.tracker(tracker_row(es, unit: "pain 1-10"), es, @now, @tz)
      assert hd(row.recent).value == "6.5"
      assert row.last == "Today · 6.5"
    end

    test "the body carries its own empty-state copy" do
      body = F.trackers([], %{}, @now, @tz)
      assert body.items == []
      assert body.empty == "No trackers yet."
      assert body.hint == "Try: “Henry, log a headache, about a 6.”"
    end
  end

  describe "routines" do
    defp routine(attrs) do
      struct(
        %Routine{
          id: 4,
          user_id: 1,
          name: "goodnight",
          label: "Good night",
          triggers: ["good night", "bedtime"],
          steps: "Turn off the downstairs lights. Set the thermostat to 68."
        },
        attrs
      )
    end

    test "a row: name, what to say (the name first, a trigger repeating it dropped), steps" do
      row = F.routine(routine(%{}), @now, @tz)

      assert row.id == 4
      assert row.name == "Good night"
      assert row.say == ["Good night", "bedtime"]
      assert row.steps == "Turn off the downstairs lights. Set the thermostat to 68."
      assert row.last_run == "Not run yet"
      assert row.delete_confirm == "Delete the “Good night” routine? This can't be undone."
    end

    test "last run reads relative to today" do
      ran = fn local ->
        at = local |> DateTime.from_naive!(@tz) |> DateTime.shift_zone!("Etc/UTC")
        F.routine(routine(%{last_run_at: at}), @now, @tz).last_run
      end

      assert ran.(~N[2026-10-10 06:05:00]) == "Ran today, 6:05 AM"
      assert ran.(~N[2026-10-09 22:00:00]) == "Ran yesterday"
      assert ran.(~N[2026-10-06 22:00:00]) == "Ran 4 days ago"
      assert ran.(~N[2026-08-06 22:00:00]) == "Ran Aug 6"
    end

    test "the body carries its own empty-state copy" do
      body = F.routines([], @now, @tz)
      assert body.items == []
      assert body.empty == "No routines yet."

      assert body.hint ==
               "Try: “Henry, when I say good night, turn off the lights and tell me what's first tomorrow.”"
    end
  end
end
