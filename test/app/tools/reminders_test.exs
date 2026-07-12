defmodule App.Tools.RemindersTest do
  use App.DataCase, async: false
  alias App.Tools.Reminders, as: Tool
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "d@x.com", name: "Alice"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, u} = Users.upsert_allowed("d@x.com")
    %{user: u}
  end

  defp ctx(user),
    do: %{session_id: to_string(user.id), user_id: user.id, config: App.Config.default()}

  test "create_reminder stores the reminder and echoes it back", %{user: user} do
    due = "2030-01-01T17:00:00Z"

    assert {:ok, %{body: "call mom", due_at: ^due}} =
             Tool.execute("create_reminder", %{"body" => "call mom", "due_at" => due}, ctx(user))

    assert [%{body: "call mom"}] = App.Reminders.list_upcoming(user.id)
  end

  test "create_reminder rejects a non-ISO due_at", %{user: user} do
    assert {:error, :invalid_due_at} =
             Tool.execute("create_reminder", %{"body" => "x", "due_at" => "5pm-ish"}, ctx(user))
  end

  test "list_reminders returns upcoming reminders", %{user: user} do
    due = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    {:ok, _} = App.Reminders.create(%{body: "standup", due_at: due, user_id: user.id})

    assert {:ok, %{reminders: [%{body: "standup"}]}} =
             Tool.execute("list_reminders", %{}, ctx(user))
  end

  test "create_reminder with no user returns a narrated note, not a raw error" do
    assert {:ok, %{note: note}} =
             Tool.execute(
               "create_reminder",
               %{"body" => "x", "due_at" => "2030-01-01T17:00:00Z"},
               %{session_id: "default", user_id: nil, config: App.Config.default()}
             )

    assert note =~ "no user session"
  end

  test "list_reminders with no user returns an empty list" do
    assert {:ok, %{reminders: []}} =
             Tool.execute(
               "list_reminders",
               %{},
               %{session_id: "default", user_id: nil, config: App.Config.default()}
             )
  end

  test "list_reminders items include kind", %{user: user} do
    due = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    {:ok, _} = App.Reminders.create(%{body: "call mom", due_at: due, user_id: user.id})

    assert {:ok, %{reminders: [item]}} = Tool.execute("list_reminders", %{}, ctx(user))
    assert item.kind == "reminder"
  end

  describe "create_followup" do
    test "creates a followup-kind reminder with context", %{user: user} do
      assert {:ok, result} =
               Tool.execute(
                 "create_followup",
                 %{
                   "body" => "check whether Bob replied about the contract",
                   "due_at" => "2030-01-01T17:00:00Z",
                   "context" => "I'm emailing Bob about the contract"
                 },
                 ctx(user)
               )

      assert result.body == "check whether Bob replied about the contract"
      [r] = App.Reminders.list_upcoming(user.id)
      assert r.kind == "followup"
      assert r.context == "I'm emailing Bob about the contract"
    end

    test "context is optional", %{user: user} do
      assert {:ok, _} =
               Tool.execute(
                 "create_followup",
                 %{"body" => "check on the seedlings", "due_at" => "2030-01-01T17:00:00Z"},
                 ctx(user)
               )

      [r] = App.Reminders.list_upcoming(user.id)
      assert r.context == nil
    end

    test "bad due_at and nil user behave like create_reminder", %{user: user} do
      assert {:error, :invalid_due_at} =
               Tool.execute(
                 "create_followup",
                 %{"body" => "x", "due_at" => "tomorrow-ish"},
                 ctx(user)
               )

      assert {:ok, %{note: _}} =
               Tool.execute(
                 "create_followup",
                 %{"body" => "x", "due_at" => "2030-01-01T17:00:00Z"},
                 %{session_id: "default", user_id: nil, config: App.Config.default()}
               )
    end
  end

  describe "acknowledge_reminder" do
    defp past_due,
      do: DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

    test "acks the matching pending reminder", %{user: user} do
      {:ok, r} =
        App.Reminders.create(%{user_id: user.id, body: "take out the trash", due_at: past_due()})

      {:ok, _} = App.Reminders.mark_fired(r)

      assert {:ok, %{acknowledged: "take out the trash"}} =
               Tool.execute("acknowledge_reminder", %{"reminder" => "trash"}, ctx(user))

      assert App.Reminders.list_unacknowledged(user.id) == []
    end

    test "with no match returns a benign note, not an error or a lost-reminder implication", %{
      user: user
    } do
      assert {:ok, %{note: note}} =
               Tool.execute("acknowledge_reminder", %{"reminder" => "nope"}, ctx(user))

      assert note =~ "nothing to clear"
    end

    test "an already-acknowledged reminder reads as already-done, not a failed lookup", %{
      user: user
    } do
      {:ok, r} =
        App.Reminders.create(%{user_id: user.id, body: "take out the trash", due_at: past_due()})

      {:ok, r} = App.Reminders.mark_fired(r)
      {:ok, _} = App.Reminders.acknowledge(r)

      # Henry (or the user) confirms a second time — it's no longer pending, but we must NOT imply
      # it was never saved. It reports as already cleared.
      assert {:ok, %{already_done: "take out the trash"}} =
               Tool.execute("acknowledge_reminder", %{"reminder" => "trash"}, ctx(user))
    end

    test "with no user session returns a note, not an error" do
      assert {:ok, %{note: note}} =
               Tool.execute(
                 "acknowledge_reminder",
                 %{"reminder" => "trash"},
                 %{session_id: "default", user_id: nil, config: App.Config.default()}
               )

      assert note =~ "no user session"
    end
  end

  describe "create_reminder recurrence" do
    test "stores a normalized rule and seeds remaining from count", %{user: user} do
      raw = %{
        "freq" => "Weekly",
        "interval" => 2,
        "byday" => ["TUE", "bogus", "thu"],
        "count" => 3
      }

      assert {:ok, result} =
               Tool.execute(
                 "create_reminder",
                 %{
                   "body" => "take out the bins",
                   "due_at" => "2030-01-01T17:00:00Z",
                   "recurrence" => raw
                 },
                 ctx(user)
               )

      expected = %{
        "freq" => "weekly",
        "interval" => 2,
        "byday" => ["tue", "thu"],
        "count" => 3,
        "remaining" => 3
      }

      assert result.recurrence == expected
      [r] = App.Reminders.list_upcoming(user.id)
      assert r.recurrence == expected
    end

    test "a malformed rule degrades to a one-shot with a narrated note", %{user: user} do
      assert {:ok, result} =
               Tool.execute(
                 "create_reminder",
                 %{
                   "body" => "x",
                   "due_at" => "2030-01-01T17:00:00Z",
                   "recurrence" => %{"freq" => "hourly"}
                 },
                 ctx(user)
               )

      assert result.note =~ "one-time"
      [r] = App.Reminders.list_upcoming(user.id)
      assert r.recurrence == nil
    end

    test "count <= 0 degrades to a one-shot with a note", %{user: user} do
      assert {:ok, %{note: note}} =
               Tool.execute(
                 "create_reminder",
                 %{
                   "body" => "x",
                   "due_at" => "2030-01-01T17:00:00Z",
                   "recurrence" => %{"freq" => "daily", "count" => 0}
                 },
                 ctx(user)
               )

      assert note =~ "one-time"
      [r] = App.Reminders.list_upcoming(user.id)
      assert r.recurrence == nil
    end

    test "additive invariant: no recurrence arg -> nil rule, response has no note", %{user: user} do
      assert {:ok, result} =
               Tool.execute(
                 "create_reminder",
                 %{"body" => "call mom", "due_at" => "2030-01-01T17:00:00Z"},
                 ctx(user)
               )

      refute Map.has_key?(result, :note)
      refute Map.has_key?(result, :recurrence)
      [r] = App.Reminders.list_upcoming(user.id)
      assert r.recurrence == nil
    end
  end

  describe "normalize_recurrence/1 (pure)" do
    test "defaults interval to 1; accepts integer-valued floats (JSON numbers)" do
      assert {:ok, %{"interval" => 1}} = Tool.normalize_recurrence(%{"freq" => "daily"})

      assert {:ok, %{"interval" => 3}} =
               Tool.normalize_recurrence(%{"freq" => "daily", "interval" => 3.0})
    end

    test "rejects bad freq, fractional/zero interval, unparseable until, non-map input" do
      assert Tool.normalize_recurrence(%{"freq" => "fortnightly"}) == :invalid
      assert Tool.normalize_recurrence(%{"freq" => "daily", "interval" => 0}) == :invalid
      assert Tool.normalize_recurrence(%{"freq" => "daily", "interval" => 2.5}) == :invalid
      assert Tool.normalize_recurrence(%{"freq" => "daily", "until" => "next sunday"}) == :invalid
      assert Tool.normalize_recurrence("every tuesday") == :invalid
    end

    test "byday: kept for weekly (filtered, downcased, deduped); dropped otherwise; all-invalid -> omitted" do
      assert {:ok, rule} =
               Tool.normalize_recurrence(%{"freq" => "weekly", "byday" => ["TUE", "tue", "nope"]})

      assert rule["byday"] == ["tue"]

      assert {:ok, rule2} = Tool.normalize_recurrence(%{"freq" => "daily", "byday" => ["tue"]})
      refute Map.has_key?(rule2, "byday")

      assert {:ok, rule3} = Tool.normalize_recurrence(%{"freq" => "weekly", "byday" => ["nope"]})
      refute Map.has_key?(rule3, "byday")
    end

    test "until is normalized to ISO8601 UTC; count seeds remaining" do
      assert {:ok, rule} =
               Tool.normalize_recurrence(%{
                 "freq" => "daily",
                 "until" => "2026-08-01T00:00:00-05:00",
                 "count" => 4
               })

      assert rule["until"] == "2026-08-01T05:00:00Z"
      assert rule["count"] == 4
      assert rule["remaining"] == 4
    end
  end

  describe "cancel_reminder" do
    test "cancels an upcoming one-shot by phrase", %{user: user} do
      {:ok, _} =
        App.Reminders.create(%{
          user_id: user.id,
          body: "call the dentist",
          due_at: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
        })

      assert {:ok, %{cancelled: "call the dentist", was_recurring: false}} =
               Tool.execute("cancel_reminder", %{"reminder" => "dentist"}, ctx(user))

      assert App.Reminders.list_upcoming(user.id) == []
    end

    test "ends a recurring series, even mid-delivery (fired)", %{user: user} do
      {:ok, r} =
        App.Reminders.create(%{
          user_id: user.id,
          body: "take out the bins",
          due_at: past_due(),
          recurrence: %{"freq" => "weekly", "interval" => 1, "byday" => ["tue"]}
        })

      {:ok, _} = App.Reminders.mark_fired(r)

      assert {:ok, %{cancelled: "take out the bins", was_recurring: true}} =
               Tool.execute("cancel_reminder", %{"reminder" => "bins"}, ctx(user))

      assert App.Repo.reload(r) == nil
    end

    test "no match returns a benign note", %{user: user} do
      assert {:ok, %{note: note}} =
               Tool.execute("cancel_reminder", %{"reminder" => "nope"}, ctx(user))

      assert note =~ "nothing to cancel"
    end

    test "no user session returns a note, not an error" do
      assert {:ok, %{note: note}} =
               Tool.execute(
                 "cancel_reminder",
                 %{"reminder" => "bins"},
                 %{session_id: "default", user_id: nil, config: App.Config.default()}
               )

      assert note =~ "no user session"
    end
  end

  test "acknowledge_reminder on a recurring series is a friendly no-op (series kept)", %{
    user: user
  } do
    {:ok, r} =
      App.Reminders.create(%{
        user_id: user.id,
        body: "water the tomatoes",
        due_at: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
        recurrence: %{"freq" => "daily", "interval" => 3}
      })

    assert {:ok, %{recurring: "water the tomatoes", note: note}} =
             Tool.execute("acknowledge_reminder", %{"reminder" => "tomatoes"}, ctx(user))

    assert note =~ "come back around"
    # the series is neither deleted nor acknowledged
    reloaded = App.Repo.reload!(r)
    assert reloaded.acknowledged_at == nil
  end
end
