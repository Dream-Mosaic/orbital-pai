defmodule App.RemindersTest do
  use App.DataCase, async: false
  alias App.Reminders
  alias App.Reminders.Scheduler
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

  defp at(offset_s) do
    DateTime.utc_now() |> DateTime.add(offset_s, :second) |> DateTime.truncate(:second)
  end

  test "create + list_upcoming returns unfired future reminders, soonest first", %{d: d} do
    {:ok, _} = Reminders.create(%{body: "later", due_at: at(7200), user_id: d})
    {:ok, _} = Reminders.create(%{body: "soon", due_at: at(3600), user_id: d})

    assert ["soon", "later"] = Reminders.list_upcoming(d) |> Enum.map(& &1.body)
  end

  test "list_upcoming is scoped to the owning user", %{d: d, t: t} do
    {:ok, _} = Reminders.create(%{body: "mine", due_at: at(3600), user_id: d})
    {:ok, _} = Reminders.create(%{body: "theirs", due_at: at(3600), user_id: t})

    assert Enum.map(Reminders.list_upcoming(d), & &1.body) == ["mine"]
    assert Enum.map(Reminders.list_upcoming(t), & &1.body) == ["theirs"]
  end

  test "due_now returns past-due unfired reminders, not future ones", %{d: d} do
    {:ok, past} = Reminders.create(%{body: "now", due_at: at(-60), user_id: d})
    {:ok, _future} = Reminders.create(%{body: "tomorrow", due_at: at(3600), user_id: d})

    due = Reminders.due_now()
    assert Enum.map(due, & &1.id) == [past.id]
  end

  test "mark_fired stamps fired_at and removes it from due_now", %{d: d} do
    {:ok, r} = Reminders.create(%{body: "ping", due_at: at(-10), user_id: d})
    assert {:ok, fired} = Reminders.mark_fired(r)
    assert fired.fired_at != nil
    assert Reminders.due_now() == []
  end

  test "acknowledged_at persists (schema cast + migration column)", %{d: d} do
    {:ok, r} = Reminders.create(%{body: "x", due_at: at(-10), user_id: d})
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _updated} =
      r |> App.Reminders.Reminder.changeset(%{acknowledged_at: now}) |> App.Repo.update()

    assert App.Repo.reload!(r).acknowledged_at == now
  end

  test "list_unacknowledged returns fired-but-unacknowledged, excludes unfired + acknowledged", %{
    d: d
  } do
    {:ok, _unfired} = Reminders.create(%{body: "future", due_at: at(3600), user_id: d})
    {:ok, f} = Reminders.create(%{body: "fired", due_at: at(-60), user_id: d})
    {:ok, fired} = Reminders.mark_fired(f)
    {:ok, a} = Reminders.create(%{body: "acked", due_at: at(-90), user_id: d})
    {:ok, acked} = Reminders.mark_fired(a)
    {:ok, _} = Reminders.acknowledge(acked)

    assert Enum.map(Reminders.list_unacknowledged(d), & &1.body) == ["fired"]
    assert hd(Reminders.list_unacknowledged(d)).id == fired.id
  end

  test "list_unacknowledged is scoped to the owning user", %{d: d, t: t} do
    {:ok, mine} = Reminders.create(%{body: "mine", due_at: at(-60), user_id: d})
    {:ok, _} = Reminders.mark_fired(mine)
    {:ok, theirs} = Reminders.create(%{body: "theirs", due_at: at(-60), user_id: t})
    {:ok, _} = Reminders.mark_fired(theirs)

    assert Enum.map(Reminders.list_unacknowledged(d), & &1.body) == ["mine"]
    assert Enum.map(Reminders.list_unacknowledged(t), & &1.body) == ["theirs"]
  end

  test "acknowledge stamps acknowledged_at and drops it from list_unacknowledged", %{d: d} do
    {:ok, r} = Reminders.create(%{body: "a", due_at: at(-120), user_id: d})
    {:ok, fired} = Reminders.mark_fired(r)
    assert [%{body: "a"}] = Reminders.list_unacknowledged(d)

    assert {:ok, ack} = Reminders.acknowledge(fired)
    assert ack.acknowledged_at != nil
    assert Reminders.list_unacknowledged(d) == []
  end

  test "acknowledge with a non-persisted struct is a no-op (no DB write)" do
    assert Reminders.acknowledge(%Reminders.Reminder{id: nil, body: "x"}) == :ok
  end

  test "mark_delivered stamps delivered_at but leaves the reminder pending (acknowledged_at null)",
       %{d: d} do
    {:ok, r} = Reminders.create(%{user_id: d, body: "trash", due_at: at(-10)})
    {:ok, _} = Reminders.mark_fired(r)
    fired = App.Repo.get!(App.Reminders.Reminder, r.id)

    {:ok, delivered} = Reminders.mark_delivered(fired)

    assert delivered.delivered_at != nil
    assert delivered.acknowledged_at == nil
    # still pending (visible in the needs-your-OK list)
    assert Enum.any?(Reminders.list_unacknowledged(delivered.user_id), &(&1.id == delivered.id))
  end

  test "recurrence persists as a string-keyed map; a plain create stays nil (one-shot unchanged)",
       %{d: d} do
    {:ok, plain} = Reminders.create(%{body: "one-shot", due_at: at(3600), user_id: d})
    assert plain.recurrence == nil
    assert App.Repo.reload!(plain).recurrence == nil

    rule = %{"freq" => "daily", "interval" => 3, "count" => 5, "remaining" => 5}
    {:ok, r} = Reminders.create(%{body: "water", due_at: at(3600), user_id: d, recurrence: rule})

    reloaded = App.Repo.reload!(r)
    assert reloaded.recurrence == rule
    # JSON round-trip: keys stay strings, ints stay ints
    assert reloaded.recurrence["interval"] === 3
  end

  test "create requires a user_id" do
    assert {:error, %Ecto.Changeset{} = cs} = Reminders.create(%{body: "b", due_at: at(60)})
    assert %{user_id: ["can't be blank"]} = errors_on(cs)
  end

  test "create/acknowledge/delete each broadcast {:reminders_changed} on the user topic", %{d: d} do
    Phoenix.PubSub.subscribe(App.PubSub, "reminders:#{d}")

    {:ok, r} = Reminders.create(%{body: "b", due_at: at(-30), user_id: d})
    assert_receive {:reminders_changed}

    {:ok, fired} = Reminders.mark_fired(r)
    {:ok, _} = Reminders.acknowledge(fired)
    assert_receive {:reminders_changed}

    {:ok, _} = Reminders.delete(fired)
    assert_receive {:reminders_changed}
  end

  test "Scheduler.tick fires due reminders and broadcasts {:reminder_due} on the owner topic", %{
    d: d
  } do
    Phoenix.PubSub.subscribe(App.PubSub, "reminders:#{d}")
    {:ok, _} = Reminders.create(%{body: "call mom", due_at: at(-5), user_id: d})

    Scheduler.tick()

    assert_receive {:reminder_due, %App.Reminders.Reminder{body: "call mom", user_id: ^d}}
  end

  test "Scheduler.tick routes each user's due reminder to only its own topic", %{d: d, t: t} do
    {:ok, _} = Reminders.create(%{body: "d-rem", due_at: at(-60), user_id: d})
    {:ok, _} = Reminders.create(%{body: "t-rem", due_at: at(-60), user_id: t})

    # subscribe AFTER the creates so we only capture the tick's {:reminder_due}, not {:reminders_changed}
    Phoenix.PubSub.subscribe(App.PubSub, "reminders:#{d}")

    Scheduler.tick()

    # Alice's topic receives ONLY Alice's reminder, never Bob's
    assert_receive {:reminder_due, %App.Reminders.Reminder{body: "d-rem", user_id: ^d}}, 1000
    refute_receive {:reminder_due, %App.Reminders.Reminder{body: "t-rem"}}, 200
  end

  describe "kind + context" do
    test "kind defaults to reminder; followup kind and context are stored", %{d: d} do
      {:ok, plain} =
        Reminders.create(%{user_id: d, body: "call mom", due_at: at(3600)})

      assert plain.kind == "reminder"
      assert plain.context == nil

      {:ok, fu} =
        Reminders.create(%{
          user_id: d,
          body: "check whether Bob replied about the contract",
          due_at: at(3600),
          kind: "followup",
          context: "I'm emailing Bob about the contract"
        })

      assert fu.kind == "followup"
      assert fu.context == "I'm emailing Bob about the contract"
    end

    test "unknown kinds are rejected", %{d: d} do
      assert {:error, changeset} =
               Reminders.create(%{
                 user_id: d,
                 body: "x",
                 due_at: at(3600),
                 kind: "nag"
               })

      assert %{kind: _} = errors_on(changeset)
    end
  end

  describe "household (shared) reminders" do
    test "list_upcoming returns the user's own + all household reminders, not other users' personal",
         %{d: d, t: t} do
      {:ok, _mine} = Reminders.create(%{user_id: d, body: "mine", due_at: at(3600)})
      {:ok, _theirs} = Reminders.create(%{user_id: t, body: "theirs", due_at: at(3600)})

      {:ok, _shared} =
        Reminders.create(%{user_id: t, body: "bins", due_at: at(3600), household: true})

      bodies = Reminders.list_upcoming(d) |> Enum.map(& &1.body) |> Enum.sort()
      assert bodies == ["bins", "mine"]
    end

    test "list_unacknowledged returns the user's own + all household fired reminders, not other users' personal",
         %{d: d, t: t} do
      {:ok, mine} = Reminders.create(%{user_id: d, body: "mine", due_at: at(-60)})
      {:ok, _} = Reminders.mark_fired(mine)

      {:ok, theirs} = Reminders.create(%{user_id: t, body: "theirs", due_at: at(-60)})
      {:ok, _} = Reminders.mark_fired(theirs)

      {:ok, shared} =
        Reminders.create(%{user_id: t, body: "bins", due_at: at(-60), household: true})

      {:ok, _} = Reminders.mark_fired(shared)

      bodies = Reminders.list_unacknowledged(d) |> Enum.map(& &1.body) |> Enum.sort()
      assert bodies == ["bins", "mine"]
    end

    test "list_household_upcoming returns only household rows", %{d: d} do
      {:ok, _} = Reminders.create(%{user_id: d, body: "mine", due_at: at(3600)})
      {:ok, _} = Reminders.create(%{user_id: d, body: "bins", due_at: at(3600), household: true})
      assert Reminders.list_household_upcoming() |> Enum.map(& &1.body) == ["bins"]
    end

    test "creating a household reminder broadcasts on reminders:household", %{d: d} do
      Phoenix.PubSub.subscribe(App.PubSub, "reminders:household")
      {:ok, _} = Reminders.create(%{user_id: d, body: "bins", due_at: at(3600), household: true})
      assert_receive {:reminders_changed}, 500
    end

    test "creating a PERSONAL reminder does NOT broadcast on reminders:household", %{d: d} do
      Phoenix.PubSub.subscribe(App.PubSub, "reminders:household")
      {:ok, _} = Reminders.create(%{user_id: d, body: "mine", due_at: at(3600)})
      refute_receive {:reminders_changed}, 300
    end
  end

  describe "find_pending/2" do
    test "best-matches a spoken phrase against the user's pending reminders (own + household)", %{
      d: d
    } do
      {:ok, mine} = Reminders.create(%{user_id: d, body: "take out the trash", due_at: at(-3600)})
      {:ok, _} = Reminders.mark_fired(mine)

      {:ok, shared} =
        Reminders.create(%{
          user_id: d,
          body: "take out the bins",
          due_at: at(-3600),
          household: true
        })

      {:ok, _} = Reminders.mark_fired(shared)

      assert Reminders.find_pending(d, "trash").body == "take out the trash"
      assert Reminders.find_pending(d, "bins").body == "take out the bins"
      assert Reminders.find_pending(d, "nonexistent thing") == nil
    end

    test "ignores already-acknowledged reminders", %{d: d} do
      {:ok, r} = Reminders.create(%{user_id: d, body: "call mom", due_at: at(-3600)})
      {:ok, r} = Reminders.mark_fired(r)
      {:ok, _} = Reminders.acknowledge(r)
      assert Reminders.find_pending(d, "call mom") == nil
    end
  end

  describe "find_acknowledged/2" do
    test "matches an already-acknowledged reminder (the complement of find_pending)", %{d: d} do
      {:ok, r} = Reminders.create(%{user_id: d, body: "take out the trash", due_at: at(-3600)})
      {:ok, r} = Reminders.mark_fired(r)
      {:ok, _} = Reminders.acknowledge(r)

      # Not pending anymore, but findable as already-cleared so the tool can say so.
      assert Reminders.find_pending(d, "trash") == nil
      assert Reminders.find_acknowledged(d, "trash").body == "take out the trash"
    end

    test "returns nil for a phrase that never existed, and for a pending (unacked) one", %{d: d} do
      {:ok, pending} = Reminders.create(%{user_id: d, body: "water plants", due_at: at(-3600)})
      {:ok, _} = Reminders.mark_fired(pending)

      assert Reminders.find_acknowledged(d, "never set this") == nil
      # a still-pending reminder is NOT "already acknowledged"
      assert Reminders.find_acknowledged(d, "water plants") == nil
    end
  end
end
