defmodule App.Timers.SchedulerTest do
  # async: false — the scheduler is a separate process sharing the sandbox, and it registers
  # under its global name (the app doesn't start it in test: `start_timer_scheduler: false`).
  use App.DataCase, async: false

  alias App.Timers
  alias App.Timers.{Scheduler, Timer}
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "a@x.com", name: "Alice"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, alice} = Users.upsert_allowed("a@x.com")
    Phoenix.PubSub.subscribe(App.PubSub, "agenda:#{alice.id}")
    %{alice: alice}
  end

  # Insert a timer row directly, as if it had been running across a restart.
  defp running!(user, ends_in_ms, label \\ nil) do
    now = DateTime.utc_now()

    %Timer{}
    |> Timer.changeset(%{
      user_id: user.id,
      label: label,
      duration_ms: 60_000,
      ends_at: DateTime.add(now, ends_in_ms, :millisecond),
      state: "running"
    })
    |> Repo.insert!()
  end

  defp state_of(%Timer{id: id}), do: Repo.get!(Timer, id).state

  test "a created timer fires on time: ringing + a canned agenda item", %{alice: alice} do
    start_supervised!(Scheduler)
    {:ok, t} = Timers.create(alice.id, 1, "pasta")

    refute_receive {:agenda_due, _}, 700
    assert_receive {:agenda_due, %App.Agenda.Item{} = item}, 1_500

    assert item.kind == :timer
    assert item.canned == true
    assert item.prompt == "Your pasta timer is up."
    assert state_of(t) == "ringing"
  end

  test "a cancelled timer never rings", %{alice: alice} do
    start_supervised!(Scheduler)
    {:ok, t} = Timers.create(alice.id, 1)
    {:ok, _} = Timers.cancel(alice.id, t.id)

    refute_receive {:agenda_due, _}, 1_400
    assert state_of(t) == "cancelled"
  end

  test "a ringing timer nobody dismisses settles to done", %{alice: alice} do
    t = running!(alice, 20)
    start_supervised!({Scheduler, ring_ms: 50})

    assert_receive {:agenda_due, %App.Agenda.Item{kind: :timer}}, 500
    Process.sleep(150)
    assert state_of(t) == "done"
  end

  describe "boot reload" do
    test "re-arms timers still running in the future", %{alice: alice} do
      t = running!(alice, 200, "eggs")
      start_supervised!(Scheduler)

      assert_receive {:agenda_due, %App.Agenda.Item{prompt: "Your eggs timer is up."}}, 1_000
      assert state_of(t) == "ringing"
    end

    test "a timer that came due < 15 min ago fires late", %{alice: alice} do
      t = running!(alice, -5 * 60_000, "tea")
      start_supervised!(Scheduler)

      assert_receive {:agenda_due, %App.Agenda.Item{prompt: "Your tea timer is up."}}, 500
      assert state_of(t) == "ringing"
    end

    test "a timer that came due >= 15 min ago is marked done silently", %{alice: alice} do
      t = running!(alice, -16 * 60_000, "roast")
      start_supervised!(Scheduler)

      refute_receive {:agenda_due, _}, 300
      assert state_of(t) == "done"
    end

    test "a timer left ringing past the settle window is settled", %{alice: alice} do
      t = running!(alice, -60_000)
      {:ok, _} = Timers.fire(t.id)
      fired = DateTime.add(DateTime.utc_now(), -10 * 60_000, :millisecond)
      Repo.update!(Ecto.Changeset.change(Repo.get!(Timer, t.id), fired_at: fired))

      start_supervised!(Scheduler)
      Process.sleep(100)
      assert state_of(t) == "done"
    end
  end
end
