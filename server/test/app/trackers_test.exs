defmodule App.TrackersTest do
  use App.DataCase, async: false
  alias App.Trackers
  alias App.Trackers.{Entry, Tracker}
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "d@x.com", name: "Alice"},
      %{email: "t@x.com", name: "Bob"}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, d} = Users.upsert_allowed("d@x.com")
    {:ok, t} = Users.upsert_allowed("t@x.com")
    %{d: d.id, t: t.id}
  end

  describe "normalize/1" do
    test "lowercases, trims, collapses whitespace and singularizes the last word" do
      assert Trackers.normalize("  Headaches ") == "headache"
      assert Trackers.normalize("Back   Pain") == "back pain"
      assert Trackers.normalize("allergies") == "allergy"
      assert Trackers.normalize("glass") == "glass"
      assert Trackers.normalize("sinus") == "sinus"
    end

    test "drops possessive/article prefixes and a trailing 'tracker'" do
      assert Trackers.normalize("my headaches") == "headache"
      assert Trackers.normalize("the weight tracker") == "weight"
      assert Trackers.normalize("My Sleep log.") == "sleep"
    end

    test "blank or prefix-only names normalize to nil" do
      assert Trackers.normalize("") == nil
      assert Trackers.normalize("   ") == nil
      assert Trackers.normalize("my") == nil
      assert Trackers.normalize(nil) == nil
    end
  end

  describe "log/3" do
    test "auto-creates the tracker on first use, then reuses it", %{d: d} do
      assert {:ok, %{tracker: t1, entry: e1, created: true}} =
               Trackers.log(d, "Headaches", %{value: 6, unit: "pain 1–10"})

      assert t1.name == "headache"
      assert t1.label == "Headaches"
      assert t1.unit == "pain 1–10"
      assert e1.value == 6.0

      assert {:ok, %{tracker: t2, created: false}} = Trackers.log(d, "headache", %{value: 3})
      assert t2.id == t1.id
      assert Repo.aggregate(Tracker, :count) == 1
      assert Repo.aggregate(Entry, :count) == 2
    end

    test "singular/plural names collide in either order", %{d: d} do
      {:ok, %{tracker: a}} = Trackers.log(d, "headache", %{})
      {:ok, %{tracker: b}} = Trackers.log(d, "my headaches", %{})
      assert a.id == b.id

      {:ok, %{tracker: m1}} = Trackers.log(d, "matches", %{})
      {:ok, %{tracker: m2}} = Trackers.log(d, "match", %{})
      assert m1.id == m2.id

      {:ok, %{tracker: g1}} = Trackers.log(d, "glass", %{})
      {:ok, %{tracker: g2}} = Trackers.log(d, "glasses", %{})
      assert g1.id == g2.id

      {:ok, %{tracker: al1}} = Trackers.log(d, "allergies", %{})
      {:ok, %{tracker: al2}} = Trackers.log(d, "Allergy", %{})
      assert al1.id == al2.id

      assert Repo.aggregate(Tracker, :count) == 4
    end

    test "different things stay different trackers", %{d: d} do
      {:ok, %{tracker: a}} = Trackers.log(d, "headache", %{})
      {:ok, %{tracker: b}} = Trackers.log(d, "back pain", %{})
      refute a.id == b.id
    end

    test "unit is set on first use and never overwritten (but fills a missing one)", %{d: d} do
      {:ok, _} = Trackers.log(d, "weight", %{value: 182.4, unit: "lb"})
      {:ok, %{tracker: t}} = Trackers.log(d, "weight", %{value: 181.0, unit: "kg"})
      assert t.unit == "lb"

      {:ok, %{tracker: s}} = Trackers.log(d, "sleep", %{value: 7})
      assert s.unit == nil
      {:ok, %{tracker: s}} = Trackers.log(d, "sleep", %{value: 6.5, unit: "hours"})
      assert s.unit == "hours"
    end

    test "an entry needs no value, note or tags — the event is the data point", %{d: d} do
      assert {:ok, %{entry: e}} = Trackers.log(d, "headache", %{})
      assert e.value == nil
      assert e.note == nil
      assert e.tags == []
      assert %DateTime{} = e.recorded_at
    end

    test "tags are trimmed, lowercased, de-duplicated and blank-free", %{d: d} do
      {:ok, %{entry: e}} =
        Trackers.log(d, "headache", %{tags: [" Skipped lunch ", "coffee", "COFFEE", "", "  "]})

      assert e.tags == ["skipped lunch", "coffee"]
      assert Repo.get!(Entry, e.id).tags == ["skipped lunch", "coffee"]
    end

    test "recorded_at defaults to now and honors a backdated time", %{d: d} do
      before = DateTime.utc_now()
      {:ok, %{entry: now_entry}} = Trackers.log(d, "headache", %{})
      assert DateTime.compare(now_entry.recorded_at, before) != :lt

      {:ok, %{entry: back}} =
        Trackers.log(d, "headache", %{recorded_at: ~U[2026-10-01 18:30:00Z], note: "bad one"})

      assert DateTime.compare(back.recorded_at, ~U[2026-10-01 18:30:00Z]) == :eq
      assert Repo.get!(Entry, back.id).note == "bad one"
    end

    test "a blank name is refused", %{d: d} do
      assert {:error, :invalid_name} = Trackers.log(d, "  ", %{value: 1})
      assert {:error, :invalid_name} = Trackers.log(d, "my", %{value: 1})
      assert Repo.aggregate(Tracker, :count) == 0
    end
  end

  describe "per-user privacy" do
    test "each user gets their own tracker and never sees the other's entries", %{d: d, t: t} do
      {:ok, %{tracker: dt}} = Trackers.log(d, "headache", %{value: 6})
      {:ok, %{tracker: tt, created: true}} = Trackers.log(t, "headaches", %{value: 2})
      refute dt.id == tt.id

      {:ok, _tracker, d_entries} = Trackers.entries(d, "headache", nil, nil)
      assert Enum.map(d_entries, & &1.value) == [6.0]

      {:ok, _tracker, t_entries} = Trackers.entries(t, "headache", nil, nil)
      assert Enum.map(t_entries, & &1.value) == [2.0]

      assert [%{tracker: %{id: id}}] = Trackers.list(d)
      assert id == dt.id
    end

    test "undo and delete never reach across users", %{d: d, t: t} do
      {:ok, _} = Trackers.log(d, "headache", %{value: 6})
      assert {:error, :not_found} = Trackers.delete_last(t, "headache")
      assert {:error, :not_found} = Trackers.delete_tracker(t, "headache")
      assert {:ok, _, [_]} = Trackers.entries(d, "headache", nil, nil)
    end
  end

  describe "entries/4" do
    setup %{d: d} do
      for {at, v} <- [
            {~U[2026-10-01 12:00:00Z], 1},
            {~U[2026-10-03 12:00:00Z], 3},
            {~U[2026-10-05 12:00:00Z], 5}
          ] do
        {:ok, _} = Trackers.log(d, "headache", %{recorded_at: at, value: v})
      end

      :ok
    end

    test "newest first, unbounded when since/until are nil", %{d: d} do
      {:ok, tracker, entries} = Trackers.entries(d, "headaches", nil, nil)
      assert tracker.name == "headache"
      assert Enum.map(entries, & &1.value) == [5.0, 3.0, 1.0]
    end

    test "since/until bound the range inclusively", %{d: d} do
      {:ok, _, entries} =
        Trackers.entries(d, "headache", ~U[2026-10-03 12:00:00Z], ~U[2026-10-05 12:00:00Z])

      assert Enum.map(entries, & &1.value) == [5.0, 3.0]

      {:ok, _, entries} = Trackers.entries(d, "headache", nil, ~U[2026-10-02 00:00:00Z])
      assert Enum.map(entries, & &1.value) == [1.0]
    end

    test "an unknown tracker is :not_found", %{d: d} do
      assert {:error, :not_found} = Trackers.entries(d, "weight", nil, nil)
    end
  end

  describe "list/1" do
    test "every tracker with its entry count and latest entry, most recently active first",
         %{d: d} do
      {:ok, _} = Trackers.log(d, "headache", %{recorded_at: ~U[2026-10-01 12:00:00Z], value: 4})
      {:ok, _} = Trackers.log(d, "headache", %{recorded_at: ~U[2026-10-08 12:00:00Z], value: 7})
      # backdated after the fact: still not the latest
      {:ok, _} = Trackers.log(d, "headache", %{recorded_at: ~U[2026-10-02 12:00:00Z], value: 2})
      {:ok, _} = Trackers.log(d, "weight", %{recorded_at: ~U[2026-10-05 12:00:00Z], value: 180})

      assert [
               %{tracker: %{name: "headache"}, count: 3, last_entry: %{value: 7.0}},
               %{tracker: %{name: "weight"}, count: 1, last_entry: %{value: 180.0}}
             ] = Trackers.list(d)
    end

    test "empty for a user with no trackers", %{d: d} do
      assert Trackers.list(d) == []
    end
  end

  describe "delete_last/2" do
    test "removes the most recently LOGGED entry (scratch that), even if backdated", %{d: d} do
      {:ok, _} = Trackers.log(d, "headache", %{recorded_at: ~U[2026-10-08 12:00:00Z], value: 7})

      {:ok, %{entry: oops}} =
        Trackers.log(d, "headache", %{recorded_at: ~U[2026-10-01 12:00:00Z], value: 9})

      assert {:ok, tracker, undone} = Trackers.delete_last(d, "headaches")
      assert undone.id == oops.id
      assert tracker.name == "headache"
      assert Repo.get(Entry, oops.id) == nil
      assert {:ok, _, [%{value: 7.0}]} = Trackers.entries(d, "headache", nil, nil)
    end

    test "an empty tracker is :empty; an unknown one :not_found", %{d: d} do
      {:ok, _} = Trackers.log(d, "headache", %{})
      {:ok, _, _} = Trackers.delete_last(d, "headache")
      assert {:error, :empty} = Trackers.delete_last(d, "headache")
      assert {:error, :not_found} = Trackers.delete_last(d, "weight")
    end
  end

  describe "delete_tracker/2" do
    test "removes the tracker and all its entries", %{d: d} do
      {:ok, _} = Trackers.log(d, "headache", %{value: 1})
      {:ok, _} = Trackers.log(d, "headache", %{value: 2})
      {:ok, _} = Trackers.log(d, "weight", %{value: 180})

      assert {:ok, %Tracker{name: "headache"}, 2} = Trackers.delete_tracker(d, "Headaches")
      assert [%{tracker: %{name: "weight"}}] = Trackers.list(d)
      assert Repo.aggregate(Entry, :count) == 1
      assert {:error, :not_found} = Trackers.delete_tracker(d, "headache")
    end
  end

  describe "stats/2 (pure)" do
    # America/Chicago is UTC-5 (CDT) in early October 2026.
    defp fixture do
      [
        # Mon Oct 5, 09:00 local
        %Entry{recorded_at: ~U[2026-10-05 14:00:00Z], value: 4.0, tags: ["coffee"]},
        # Mon Oct 5, 22:00 local — Tuesday in UTC; must bucket as MONDAY locally
        %Entry{
          recorded_at: ~U[2026-10-06 03:00:00Z],
          value: 6.0,
          tags: ["skipped lunch", "coffee"]
        },
        # Tue Oct 6, 13:00 local
        %Entry{recorded_at: ~U[2026-10-06 18:00:00Z], value: 8.0, tags: ["Coffee"]},
        # Wed Oct 7 — no value
        %Entry{recorded_at: ~U[2026-10-07 15:00:00Z], value: nil, tags: []},
        # Mon Oct 12
        %Entry{recorded_at: ~U[2026-10-12 15:00:00Z], value: 2.0, tags: ["poor sleep"]}
      ]
      |> Enum.shuffle()
    end

    test "counts, value summary and local first/last dates" do
      s = Trackers.stats(fixture(), "America/Chicago")
      assert s.count == 5
      assert s.days_with_entries == 4
      assert s.first_date == "2026-10-05"
      assert s.last_date == "2026-10-12"
      assert s.value == %{count: 4, min: 2, max: 8, avg: 5}
    end

    test "weekday buckets use LOCAL dates and list all seven days Monday-first" do
      s = Trackers.stats(fixture(), "America/Chicago")

      assert Enum.map(s.by_weekday, & &1.weekday) ==
               ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

      [mon, tue, wed, thu | _] = s.by_weekday
      assert mon == %{weekday: "Monday", count: 3, avg_value: 4}
      assert tue == %{weekday: "Tuesday", count: 1, avg_value: 8}
      assert wed == %{weekday: "Wednesday", count: 1, avg_value: nil}
      assert thu == %{weekday: "Thursday", count: 0, avg_value: nil}

      utc = Trackers.stats(fixture(), "Etc/UTC")

      assert [%{weekday: "Monday", count: 2}, %{weekday: "Tuesday", count: 2} | _] =
               utc.by_weekday
    end

    test "weekly buckets (Monday-start), oldest first" do
      s = Trackers.stats(fixture(), "America/Chicago")

      assert s.by_week == [
               %{week_of: "2026-10-05", count: 4, avg_value: 6},
               %{week_of: "2026-10-12", count: 1, avg_value: 2}
             ]
    end

    test "weekly buckets include empty weeks between active ones" do
      entries = [
        %Entry{recorded_at: ~U[2026-09-21 15:00:00Z], value: 1.0, tags: []},
        %Entry{recorded_at: ~U[2026-10-07 15:00:00Z], value: 3.0, tags: []}
      ]

      assert Trackers.stats(entries, "America/Chicago").by_week == [
               %{week_of: "2026-09-21", count: 1, avg_value: 1},
               %{week_of: "2026-09-28", count: 0, avg_value: nil},
               %{week_of: "2026-10-05", count: 1, avg_value: 3}
             ]
    end

    test "longest streak of consecutive days and longest entry-free gap" do
      s = Trackers.stats(fixture(), "America/Chicago")
      assert s.longest_streak == %{days: 3, from: "2026-10-05", to: "2026-10-07"}
      assert s.longest_gap == %{days: 4, from: "2026-10-07", to: "2026-10-12"}
    end

    test "top tags are case-insensitive, by count then alphabetical" do
      s = Trackers.stats(fixture(), "America/Chicago")

      assert s.top_tags == [
               %{tag: "coffee", count: 3},
               %{tag: "poor sleep", count: 1},
               %{tag: "skipped lunch", count: 1}
             ]
    end

    test "non-integral averages round to two decimals" do
      entries = [
        %Entry{recorded_at: ~U[2026-10-05 15:00:00Z], value: 1.0, tags: []},
        %Entry{recorded_at: ~U[2026-10-05 16:00:00Z], value: 2.0, tags: []},
        %Entry{recorded_at: ~U[2026-10-05 17:00:00Z], value: 2.0, tags: []}
      ]

      assert Trackers.stats(entries, "America/Chicago").value.avg == 1.67
    end

    test "empty and single-day inputs" do
      empty = Trackers.stats([], "America/Chicago")
      assert empty.count == 0
      assert empty.value == nil
      assert empty.longest_streak == nil
      assert empty.longest_gap == nil
      assert empty.by_week == []
      assert empty.top_tags == []
      assert empty.first_date == nil

      one = Trackers.stats([%Entry{recorded_at: ~U[2026-10-05 15:00:00Z]}], "America/Chicago")
      assert one.longest_streak == %{days: 1, from: "2026-10-05", to: "2026-10-05"}
      assert one.longest_gap == nil
      assert one.value == nil
    end
  end
end
