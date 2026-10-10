defmodule App.Tools.TrackersTest do
  use App.DataCase, async: false
  alias App.Tools.Trackers, as: Tool
  alias App.Trackers
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "d@x.com", name: "Alice"},
      %{email: "t@x.com", name: "Bob"}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, u} = Users.upsert_allowed("d@x.com")
    {:ok, other} = Users.upsert_allowed("t@x.com")
    %{user: u, other: other}
  end

  defp ctx(user),
    do: %{session_id: to_string(user.id), user_id: user.id, config: App.Config.default()}

  defp no_session, do: %{session_id: "default", user_id: nil, config: App.Config.default()}

  defp iso(dt), do: DateTime.to_iso8601(dt)
  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)
  defp days_ago(n), do: ago(n * 86_400)

  # Every {:ok, map} result goes back into the next Gemini request as JSON.
  defp json!(result), do: result |> Jason.encode!() |> Jason.decode!()

  describe "registration" do
    test "declares the five tracker functions, each with its required args" do
      decls = Map.new(Tool.declarations(), &{&1.name, &1})

      assert Map.keys(decls) |> Enum.sort() ==
               ~w(delete_tracker get_tracker_entries list_trackers log_tracker_entry undo_tracker_entry)

      assert decls["log_tracker_entry"].parameters.required == ["tracker"]
      assert decls["get_tracker_entries"].parameters.required == ["tracker"]
      assert decls["list_trackers"].parameters.required == []
      assert decls["undo_tracker_entry"].parameters.required == ["tracker"]
      assert decls["delete_tracker"].parameters.required == ["tracker"]
    end

    test "is enabled in the default config and advertises itself in the brain prompt" do
      assert App.Tools.Trackers in App.Config.default().tools

      prompt = Tool.prompt()
      assert prompt =~ "log_tracker_entry"
      assert prompt =~ "get_tracker_entries"
      assert prompt =~ "undo_tracker_entry"
      assert prompt =~ "delete_tracker"
      assert App.Tools.prompt_block(App.Config.default()) =~ prompt
    end

    test "no bridge phrases (DB-local, fast)" do
      assert Tool.bridge("log_tracker_entry") == []
      assert Tool.bridge("get_tracker_entries") == []
    end
  end

  describe "log_tracker_entry" do
    test "auto-creates the tracker and logs value, note, tags and unit", %{user: user} do
      assert {:ok, result} =
               Tool.execute(
                 "log_tracker_entry",
                 %{
                   "tracker" => "headaches",
                   "value" => 6,
                   "note" => "behind the eyes",
                   "tags" => ["Skipped lunch", "coffee"],
                   "unit" => "pain 1-10"
                 },
                 ctx(user)
               )

      assert result.logged == true
      assert result.created == true
      assert result.tracker == "headaches"
      assert result.unit == "pain 1-10"
      assert result.total_entries == 1
      assert result.entry.value == 6
      assert result.entry.note == "behind the eyes"
      assert result.entry.tags == ["skipped lunch", "coffee"]
      json!(result)

      assert {:ok, %{created: false, total_entries: 2}} =
               Tool.execute("log_tracker_entry", %{"tracker" => "headache"}, ctx(user))
    end

    test "a backdated recorded_at gets LOCAL display fields (instance timezone)", %{user: user} do
      # 14:00Z on Mon Oct 5 2026 is 9:00 AM in America/Chicago (CDT).
      assert {:ok, %{entry: entry}} =
               Tool.execute(
                 "log_tracker_entry",
                 %{"tracker" => "headache", "recorded_at" => "2026-10-05T14:00:00Z"},
                 ctx(user)
               )

      assert entry.recorded_at == "2026-10-05T14:00:00Z"
      assert entry.local_date == "2026-10-05"
      assert entry.weekday == "Monday"
      assert entry.local_time == "9:00 AM"

      # 03:00Z Tue = 10 PM Monday locally
      assert {:ok, %{entry: late}} =
               Tool.execute(
                 "log_tracker_entry",
                 %{"tracker" => "headache", "recorded_at" => "2026-10-06T03:00:00Z"},
                 ctx(user)
               )

      assert late.local_date == "2026-10-05"
      assert late.weekday == "Monday"
      assert late.local_time == "10:00 PM"
    end

    test "accepts a numeric string value; a non-numeric one is an error", %{user: user} do
      assert {:ok, %{entry: %{value: 7.5}}} =
               Tool.execute(
                 "log_tracker_entry",
                 %{"tracker" => "sleep", "value" => "7.5"},
                 ctx(user)
               )

      assert {:error, :invalid_value} =
               Tool.execute(
                 "log_tracker_entry",
                 %{"tracker" => "sleep", "value" => "a lot"},
                 ctx(user)
               )
    end

    test "a single tag string is accepted as one tag", %{user: user} do
      assert {:ok, %{entry: %{tags: ["poor sleep"]}}} =
               Tool.execute(
                 "log_tracker_entry",
                 %{"tracker" => "headache", "tags" => "poor sleep"},
                 ctx(user)
               )
    end

    test "bad or missing args are errors and save nothing", %{user: user} do
      assert {:error, :missing_args} = Tool.execute("log_tracker_entry", %{}, ctx(user))

      assert {:error, :invalid_tracker} =
               Tool.execute("log_tracker_entry", %{"tracker" => "  "}, ctx(user))

      assert {:error, :invalid_recorded_at} =
               Tool.execute(
                 "log_tracker_entry",
                 %{"tracker" => "headache", "recorded_at" => "yesterday"},
                 ctx(user)
               )

      assert {:error, :recorded_at_in_future} =
               Tool.execute(
                 "log_tracker_entry",
                 %{"tracker" => "headache", "recorded_at" => iso(ago(-3600))},
                 ctx(user)
               )

      assert Trackers.list(user.id) == []
    end

    test "no user session: nothing saved", %{user: user} do
      assert {:ok, %{note: note}} =
               Tool.execute("log_tracker_entry", %{"tracker" => "headache"}, no_session())

      assert note =~ "no user session"
      assert Trackers.list(user.id) == []
    end
  end

  describe "get_tracker_entries" do
    test "defaults to the last 30 days, newest first, with stats and local fields",
         %{user: user} do
      for {n, v} <- [{40, 9}, {10, 4}, {3, 6}, {1, 5}] do
        {:ok, _} =
          Trackers.log(user.id, "headache", %{recorded_at: days_ago(n), value: v, tags: ["x"]})
      end

      assert {:ok, result} =
               Tool.execute("get_tracker_entries", %{"tracker" => "my headaches"}, ctx(user))

      assert result.tracker == "headache"
      assert result.timezone == "America/Chicago"
      assert result.total == 3
      assert result.returned == 3
      assert result.truncated == false
      assert Enum.map(result.entries, & &1.value) == [5, 6, 4]
      assert Enum.all?(result.entries, &(is_binary(&1.local_date) and is_binary(&1.weekday)))
      assert result.stats.count == 3
      assert result.stats.value == %{count: 3, min: 4, max: 6, avg: 5}
      assert result.stats.top_tags == [%{tag: "x", count: 3}]
      assert is_binary(result.since) and is_binary(result.until)

      decoded = json!(result)
      assert decoded["stats"]["by_weekday"] |> length() == 7
    end

    test "since/until bound the range (ISO8601 UTC or a plain local date)", %{user: user} do
      for {at, v} <- [
            {~U[2026-09-30 15:00:00Z], 1},
            {~U[2026-10-01 15:00:00Z], 2},
            {~U[2026-10-03 15:00:00Z], 3},
            # 2026-10-04 03:00Z is Oct 3, 10 PM in Chicago
            {~U[2026-10-04 03:00:00Z], 4},
            {~U[2026-10-05 15:00:00Z], 5}
          ] do
        {:ok, _} = Trackers.log(user.id, "headache", %{recorded_at: at, value: v})
      end

      assert {:ok, %{entries: entries}} =
               Tool.execute(
                 "get_tracker_entries",
                 %{
                   "tracker" => "headache",
                   "since" => "2026-10-01T00:00:00Z",
                   "until" => "2026-10-03T23:59:59Z"
                 },
                 ctx(user)
               )

      assert Enum.map(entries, & &1.value) == [3, 2]

      # plain dates are whole LOCAL days: Oct 1 00:00 → Oct 3 23:59:59 Chicago
      assert {:ok, %{entries: entries, since: "2026-10-01", until: "2026-10-03"}} =
               Tool.execute(
                 "get_tracker_entries",
                 %{"tracker" => "headache", "since" => "2026-10-01", "until" => "2026-10-03"},
                 ctx(user)
               )

      assert Enum.map(entries, & &1.value) == [4, 3, 2]
    end

    test "caps at 100 entries newest-first, flags truncation, stats cover everything",
         %{user: user} do
      for n <- 1..105 do
        {:ok, _} = Trackers.log(user.id, "water", %{recorded_at: ago(n * 600), value: n})
      end

      assert {:ok, result} =
               Tool.execute("get_tracker_entries", %{"tracker" => "water"}, ctx(user))

      assert result.total == 105
      assert result.returned == 100
      assert result.truncated == true
      assert result.note =~ "100"
      assert length(result.entries) == 100
      assert hd(result.entries).value == 1
      assert result.stats.count == 105
    end

    test "an empty range says so", %{user: user} do
      {:ok, _} = Trackers.log(user.id, "headache", %{recorded_at: days_ago(60)})

      assert {:ok, %{total: 0, entries: [], note: note}} =
               Tool.execute("get_tracker_entries", %{"tracker" => "headache"}, ctx(user))

      assert note =~ "no entries"
    end

    test "an unknown tracker names the ones that exist", %{user: user} do
      {:ok, _} = Trackers.log(user.id, "weight", %{value: 180})

      assert {:ok, %{note: note, trackers: ["weight"]}} =
               Tool.execute("get_tracker_entries", %{"tracker" => "headache"}, ctx(user))

      assert note =~ "headache"
    end

    test "bad ranges are errors", %{user: user} do
      {:ok, _} = Trackers.log(user.id, "headache", %{})

      assert {:error, :invalid_since} =
               Tool.execute(
                 "get_tracker_entries",
                 %{"tracker" => "headache", "since" => "last month"},
                 ctx(user)
               )

      assert {:error, :invalid_until} =
               Tool.execute(
                 "get_tracker_entries",
                 %{"tracker" => "headache", "until" => "soon"},
                 ctx(user)
               )

      assert {:error, :invalid_range} =
               Tool.execute(
                 "get_tracker_entries",
                 %{
                   "tracker" => "headache",
                   "since" => "2026-10-05T00:00:00Z",
                   "until" => "2026-10-01T00:00:00Z"
                 },
                 ctx(user)
               )

      assert {:error, :missing_args} = Tool.execute("get_tracker_entries", %{}, ctx(user))
    end

    test "never reads another user's tracker", %{user: user, other: other} do
      {:ok, _} = Trackers.log(other.id, "headache", %{value: 9})

      assert {:ok, %{note: _, trackers: []}} =
               Tool.execute("get_tracker_entries", %{"tracker" => "headache"}, ctx(user))
    end
  end

  describe "list_trackers" do
    test "each tracker with unit, entry count and latest entry", %{user: user} do
      {:ok, _} = Trackers.log(user.id, "weight", %{value: 182.4, unit: "lb"})
      {:ok, _} = Trackers.log(user.id, "Headaches", %{value: 6})
      {:ok, _} = Trackers.log(user.id, "headache", %{value: 3})

      assert {:ok, %{trackers: [first, second]} = result} =
               Tool.execute("list_trackers", %{}, ctx(user))

      assert first.tracker == "Headaches"
      assert first.entries == 2
      assert first.last_entry.value == 3
      assert second.tracker == "weight"
      assert second.unit == "lb"
      assert second.last_entry.value == 182.4
      json!(result)
    end

    test "says so when there are none", %{user: user} do
      assert {:ok, %{trackers: [], note: _}} = Tool.execute("list_trackers", %{}, ctx(user))
    end
  end

  describe "undo_tracker_entry" do
    test "removes the last logged entry and reports what's left", %{user: user} do
      {:ok, _} = Trackers.log(user.id, "headache", %{value: 6})
      {:ok, _} = Trackers.log(user.id, "headache", %{value: 8})

      assert {:ok, result} =
               Tool.execute("undo_tracker_entry", %{"tracker" => "headaches"}, ctx(user))

      assert result.tracker == "headache"
      assert result.undone.value == 8
      assert result.remaining == 1
      json!(result)
    end

    test "unknown or empty trackers are narrated, not errors", %{user: user} do
      assert {:ok, %{note: _}} =
               Tool.execute("undo_tracker_entry", %{"tracker" => "headache"}, ctx(user))

      {:ok, _} = Trackers.log(user.id, "headache", %{})
      {:ok, _} = Tool.execute("undo_tracker_entry", %{"tracker" => "headache"}, ctx(user))

      assert {:ok, %{note: note}} =
               Tool.execute("undo_tracker_entry", %{"tracker" => "headache"}, ctx(user))

      assert note =~ "nothing"
    end
  end

  describe "delete_tracker" do
    test "deletes the tracker and its history", %{user: user} do
      {:ok, _} = Trackers.log(user.id, "headache", %{value: 6})
      {:ok, _} = Trackers.log(user.id, "headache", %{value: 8})

      assert {:ok, %{deleted: "headache", entries_deleted: 2}} =
               Tool.execute("delete_tracker", %{"tracker" => "headache"}, ctx(user))

      assert Trackers.list(user.id) == []

      assert {:ok, %{note: _}} =
               Tool.execute("delete_tracker", %{"tracker" => "headache"}, ctx(user))
    end

    test "cannot delete another user's tracker", %{user: user, other: other} do
      {:ok, _} = Trackers.log(other.id, "headache", %{value: 6})

      assert {:ok, %{note: _}} =
               Tool.execute("delete_tracker", %{"tracker" => "headache"}, ctx(user))

      assert [_] = Trackers.list(other.id)
    end
  end
end
