defmodule App.TimersTest do
  use App.DataCase, async: false

  alias App.Timers
  alias App.Timers.Timer
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "a@x.com", name: "Alice"},
      %{email: "b@x.com", name: "Bob"}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, alice} = Users.upsert_allowed("a@x.com")
    {:ok, bob} = Users.upsert_allowed("b@x.com")
    %{alice: alice, bob: bob}
  end

  describe "create/3" do
    test "stores a running timer ending duration from now; the label is trimmed, kept as said",
         %{alice: alice} do
      before = DateTime.utc_now()
      assert {:ok, %Timer{} = t} = Timers.create(alice.id, 600, "  Pasta ")

      assert t.user_id == alice.id
      assert t.label == "Pasta"
      assert t.duration_ms == 600_000
      assert t.state == "running"
      assert t.fired_at == nil

      diff = DateTime.diff(t.ends_at, before, :millisecond)
      assert diff >= 600_000 and diff < 601_000
    end

    test "a blank label is no label", %{alice: alice} do
      assert {:ok, %Timer{label: nil}} = Timers.create(alice.id, 60, "   ")
      assert {:ok, %Timer{label: nil}} = Timers.create(alice.id, 60)
    end

    test "duration is bounded to 1 s .. 24 h", %{alice: alice} do
      assert {:error, :invalid_duration} = Timers.create(alice.id, 0)
      assert {:error, :invalid_duration} = Timers.create(alice.id, -5)
      assert {:error, :invalid_duration} = Timers.create(alice.id, 86_401)
      assert {:error, :invalid_duration} = Timers.create(alice.id, "ten")
      assert {:ok, _} = Timers.create(alice.id, 1)
      assert {:ok, _} = Timers.create(alice.id, 86_400)
    end

    test "broadcasts {:timers_changed, uid} on the user's topic", %{alice: alice} do
      Phoenix.PubSub.subscribe(App.PubSub, "timers:#{alice.id}")
      {:ok, _} = Timers.create(alice.id, 60)
      assert_receive {:timers_changed, uid}
      assert uid == alice.id
    end
  end

  describe "list_active/1" do
    test "running + ringing only, soonest first, own user only", %{alice: alice, bob: bob} do
      {:ok, long} = Timers.create(alice.id, 900, "long")
      {:ok, short} = Timers.create(alice.id, 60, "short")
      {:ok, ringing} = Timers.create(alice.id, 300, "ringing")
      {:ok, _} = Timers.fire(ringing.id)
      {:ok, gone} = Timers.create(alice.id, 120, "gone")
      {:ok, _} = Timers.cancel(alice.id, gone.id)
      {:ok, _} = Timers.create(bob.id, 30, "bob's")

      assert Enum.map(Timers.list_active(alice.id), & &1.id) == [ringing.id, short.id, long.id]
    end
  end

  describe "cancel/2" do
    test "by id cancels a running timer and broadcasts", %{alice: alice} do
      {:ok, t} = Timers.create(alice.id, 60)
      Phoenix.PubSub.subscribe(App.PubSub, "timers:#{alice.id}")

      assert {:ok, [%Timer{id: id, state: "cancelled"}]} = Timers.cancel(alice.id, t.id)
      assert id == t.id
      assert_receive {:timers_changed, _}
      assert Timers.list_active(alice.id) == []
    end

    test "by id never touches another user's timer", %{alice: alice, bob: bob} do
      {:ok, theirs} = Timers.create(bob.id, 60)
      assert {:error, :not_found} = Timers.cancel(alice.id, theirs.id)
      assert [%Timer{state: "running"}] = Timers.list_active(bob.id)
    end

    test "by label matches case-insensitively and ignores a trailing 'timer'", %{alice: alice} do
      {:ok, pasta} = Timers.create(alice.id, 600, "Pasta")
      {:ok, _eggs} = Timers.create(alice.id, 300, "eggs")

      assert {:ok, [%Timer{id: id}]} = Timers.cancel(alice.id, "the pasta timer")
      assert id == pasta.id
      assert [%Timer{label: "eggs"}] = Timers.list_active(alice.id)
    end

    test "by label: none and ambiguous are distinct errors", %{alice: alice} do
      {:ok, _} = Timers.create(alice.id, 600, "pasta water")
      {:ok, _} = Timers.create(alice.id, 300, "pasta sauce")

      assert {:error, :not_found} = Timers.cancel(alice.id, "eggs")
      assert {:error, {:ambiguous, matches}} = Timers.cancel(alice.id, "pasta")
      assert length(matches) == 2
      assert length(Timers.list_active(alice.id)) == 2
    end

    test "by label: an exact match wins over a partial one", %{alice: alice} do
      {:ok, pasta} = Timers.create(alice.id, 600, "pasta")
      {:ok, _} = Timers.create(alice.id, 300, "pasta sauce")
      assert {:ok, [%Timer{id: id}]} = Timers.cancel(alice.id, "Pasta")
      assert id == pasta.id
    end

    test ":all cancels every active timer of the user only", %{alice: alice, bob: bob} do
      {:ok, _} = Timers.create(alice.id, 600)
      {:ok, r} = Timers.create(alice.id, 300)
      {:ok, _} = Timers.fire(r.id)
      {:ok, _} = Timers.create(bob.id, 60)

      assert {:ok, cancelled} = Timers.cancel(alice.id, :all)
      assert length(cancelled) == 2
      assert Timers.list_active(alice.id) == []
      assert length(Timers.list_active(bob.id)) == 1
      assert {:error, :not_found} = Timers.cancel(alice.id, :all)
    end

    test "cancelling a RINGING timer silences it (done), not cancelled", %{alice: alice} do
      {:ok, t} = Timers.create(alice.id, 60)
      {:ok, _} = Timers.fire(t.id)
      assert {:ok, [%Timer{state: "done"}]} = Timers.cancel(alice.id, t.id)
    end

    test "a stop read as RUNNING that fires in between still stops it (cancel/fire race)", %{
      alice: alice
    } do
      {:ok, stale} = Timers.create(alice.id, 60)
      {:ok, _} = Timers.fire(stale.id)
      assert {:ok, %Timer{state: "done"}} = Timers.stop_one(stale)
      refute Timers.ringing?(stale.id)
    end

    test "a queued timer notice is dropped once the timer is no longer ringing", %{alice: alice} do
      {:ok, t} = Timers.create(alice.id, 60)
      {:ok, ringing} = Timers.fire(t.id)
      item = Timers.agenda_item(ringing)
      refute App.Agenda.expired?(item)
      {:ok, _} = Timers.dismiss(alice.id, t.id)
      assert App.Agenda.expired?(item)
    end
  end

  describe "extend/3" do
    test "adds time to a running timer (by label, or the only one)", %{alice: alice} do
      {:ok, t} = Timers.create(alice.id, 600, "pasta")
      {:ok, %Timer{} = e} = Timers.extend(alice.id, "pasta", 120)
      assert DateTime.diff(e.ends_at, t.ends_at, :second) == 120
      assert e.duration_ms == 720_000
      assert {:ok, _} = Timers.extend(alice.id, nil, 60)
    end

    test "on a RINGING timer it snoozes: running again, ending that far from now", %{alice: alice} do
      {:ok, t} = Timers.create(alice.id, 60, "eggs")
      {:ok, _} = Timers.fire(t.id)
      {:ok, %Timer{state: "running"} = e} = Timers.extend(alice.id, "eggs", 300)
      left = DateTime.diff(e.ends_at, DateTime.utc_now(), :second)
      assert left in 298..300
    end

    test "nothing to extend, an ambiguous name, or a silly amount", %{alice: alice} do
      assert {:error, :not_found} = Timers.extend(alice.id, nil, 60)
      {:ok, _} = Timers.create(alice.id, 60, "pasta")
      {:ok, _} = Timers.create(alice.id, 60, "rice")
      assert {:error, {:ambiguous, _}} = Timers.extend(alice.id, nil, 60)
      assert {:error, :invalid_duration} = Timers.extend(alice.id, "pasta", 0)
    end
  end

  describe "dismiss/2" do
    test "ringing -> done, own timers only", %{alice: alice, bob: bob} do
      {:ok, t} = Timers.create(alice.id, 60)

      assert {:error, :not_found} = Timers.dismiss(alice.id, t.id),
             "a running timer isn't ringing"

      {:ok, _} = Timers.fire(t.id)

      assert {:error, :not_found} = Timers.dismiss(bob.id, t.id)
      Phoenix.PubSub.subscribe(App.PubSub, "timers:#{alice.id}")
      assert {:ok, %Timer{state: "done"}} = Timers.dismiss(alice.id, t.id)
      assert_receive {:timers_changed, _}
      assert Timers.list_active(alice.id) == []
    end
  end

  describe "fire/1 and settle_ringing/1" do
    test "fire moves running -> ringing once, stamping fired_at; idempotent", %{alice: alice} do
      {:ok, t} = Timers.create(alice.id, 60)
      Phoenix.PubSub.subscribe(App.PubSub, "timers:#{alice.id}")

      assert {:ok, %Timer{state: "ringing", fired_at: %DateTime{}}} = Timers.fire(t.id)
      assert_receive {:timers_changed, _}
      assert :noop = Timers.fire(t.id)
      refute_receive {:timers_changed, _}, 50
    end

    test "a cancelled timer never fires", %{alice: alice} do
      {:ok, t} = Timers.create(alice.id, 60)
      {:ok, _} = Timers.cancel(alice.id, t.id)
      assert :noop = Timers.fire(t.id)
    end

    test "fire on a missing id is a noop" do
      assert :noop = Timers.fire(-1)
    end

    test "settle_ringing moves ringing -> done; noop otherwise", %{alice: alice} do
      {:ok, t} = Timers.create(alice.id, 60)
      assert :noop = Timers.settle_ringing(t.id)
      {:ok, _} = Timers.fire(t.id)
      assert {:ok, %Timer{state: "done"}} = Timers.settle_ringing(t.id)
      assert :noop = Timers.settle_ringing(t.id)
    end
  end

  describe "wire/1" do
    test "the client payload computes remaining_ms now (>= 0) per active timer", %{alice: alice} do
      {:ok, run} = Timers.create(alice.id, 600, "pasta")
      {:ok, ring} = Timers.create(alice.id, 60)
      {:ok, _} = Timers.fire(ring.id)

      assert [ringing, running] = Timers.wire(alice.id)

      assert ringing == %{
               id: ring.id,
               label: nil,
               state: "ringing",
               duration_ms: 60_000,
               remaining_ms: 0
             }

      assert %{id: id, label: "pasta", state: "running", duration_ms: 600_000} = running
      assert id == run.id
      assert running.remaining_ms > 598_000 and running.remaining_ms <= 600_000
    end

    test "an overdue running timer reads 0, never negative", %{alice: alice} do
      {:ok, t} = Timers.create(alice.id, 60)
      past = DateTime.add(DateTime.utc_now(), -5, :second)
      t |> Ecto.Changeset.change(ends_at: past) |> Repo.update!()
      assert [%{remaining_ms: 0}] = Timers.wire(alice.id)
    end
  end

  describe "agenda_item/1" do
    test "a labelled timer speaks its label, canned, kind :timer" do
      item = Timers.agenda_item(%Timer{label: "pasta", duration_ms: 600_000})

      assert %App.Agenda.Item{
               kind: :timer,
               canned: true,
               deliver: :when_idle,
               prompt: "Your pasta timer is up.",
               lead_idle: "Timer's done —",
               lead_interjected: "Oh — your timer —",
               persist_as: nil
             } = item

      secs = DateTime.diff(item.expires_at, DateTime.utc_now(), :second)
      assert secs > 590 and secs <= 600
    end

    test "a label already ending in 'timer' isn't doubled" do
      assert Timers.agenda_item(%Timer{label: "Pasta timer", duration_ms: 1}).prompt ==
               "Your Pasta timer is up."
    end

    test "an unlabelled timer names its duration" do
      phrase = fn ms -> Timers.agenda_item(%Timer{label: nil, duration_ms: ms}).prompt end
      assert phrase.(600_000) == "Your 10-minute timer is up."
      assert phrase.(45_000) == "Your 45-second timer is up."
      assert phrase.(3_600_000) == "Your 1-hour timer is up."
      assert phrase.(5_400_000) == "Your 1 hour 30 minute timer is up."
      assert phrase.(90_000) == "Your 1 minute 30 second timer is up."
    end
  end
end
