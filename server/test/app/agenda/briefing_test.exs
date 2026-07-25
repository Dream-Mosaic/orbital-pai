defmodule App.Agenda.BriefingTest do
  use App.DataCase, async: false

  alias App.Agenda.{Briefing, Item}
  alias App.Users
  alias App.Users.User

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "d@x.com", name: "Alice"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, user} = Users.upsert_allowed("d@x.com")
    %{user: user}
  end

  # a zoned local DateTime in the instance zone
  defp local(str), do: DateTime.from_naive!(NaiveDateTime.from_iso8601!(str), "America/Chicago")

  describe "due_item/2 (pure)" do
    test "nil before the time, an item from the time until +5h, nil after" do
      u = %User{briefing_time: "07:00", briefing_last_on: nil}
      assert Briefing.due_item(u, local("2026-07-03T06:59:00")) == nil
      assert %Item{kind: :briefing} = Briefing.due_item(u, local("2026-07-03T07:00:00"))
      assert %Item{kind: :briefing} = Briefing.due_item(u, local("2026-07-03T11:59:00"))
      assert Briefing.due_item(u, local("2026-07-03T12:30:00")) == nil
    end

    test "nil once delivered today; an item again the next day" do
      u = %User{briefing_time: "07:00", briefing_last_on: ~D[2026-07-03]}
      assert Briefing.due_item(u, local("2026-07-03T09:00:00")) == nil
      assert %Item{kind: :briefing} = Briefing.due_item(u, local("2026-07-04T07:30:00"))
    end

    test "nil when the briefing is off (no briefing_time)" do
      assert Briefing.due_item(%User{briefing_time: nil}, local("2026-07-03T09:00:00")) == nil
    end
  end

  describe "item/2 (pure)" do
    test "briefing item shape, prompt, ack stamps at delivery, ~5h expiry" do
      item = Briefing.item(%User{id: 1}, ~D[2026-07-03])
      assert %Item{kind: :briefing, deliver: :after_next_turn, recent_context: false} = item
      assert item.persist_as == "(morning briefing)"
      assert item.lead_interjected == "Oh — and here's your morning rundown."
      assert item.prompt =~ "morning briefing"
      assert item.prompt =~ "today's weather"
      assert item.prompt =~ "reminders due today"
      assert {App.Users, :stamp_briefing!, [%User{id: 1}, ~D[2026-07-03]]} = item.ack
      assert_in_delta DateTime.diff(item.expires_at, DateTime.utc_now()), 5 * 3600, 60
    end
  end

  describe "pull/1" do
    test "an item for a due user, nil for a non-due or non-user session", %{user: user} do
      assert Briefing.pull(to_string(user.id)) == nil
      now_hhmm = Calendar.strftime(DateTime.now!(App.Config.timezone()), "%H:%M")
      {:ok, _} = Users.update_prefs(user, %{briefing_time: now_hhmm})
      assert %Item{kind: :briefing} = Briefing.pull(to_string(user.id))
      assert Briefing.pull("not-an-id") == nil
    end
  end

  describe "tick/0" do
    test "broadcasts a due user's briefing; does NOT stamp; stops once delivered", %{user: user} do
      now_hhmm = Calendar.strftime(DateTime.now!(App.Config.timezone()), "%H:%M")
      {:ok, user} = Users.update_prefs(user, %{briefing_time: now_hhmm})
      Phoenix.PubSub.subscribe(App.PubSub, "agenda:#{user.id}")

      Briefing.tick()
      assert_receive {:agenda_due, %Item{kind: :briefing}}, 1000

      # tick does NOT stamp -> a second tick still delivers (delivery is what stamps)
      Briefing.tick()
      assert_receive {:agenda_due, %Item{kind: :briefing}}, 1000

      # simulate delivery stamping today -> due_item now false -> tick delivers nothing
      Users.stamp_briefing!(user, DateTime.to_date(DateTime.now!(App.Config.timezone())))
      Briefing.tick()
      refute_receive {:agenda_due, _}, 300
    end
  end
end
