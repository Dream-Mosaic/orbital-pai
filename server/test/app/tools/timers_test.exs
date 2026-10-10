defmodule App.Tools.TimersTest do
  use App.DataCase, async: false

  alias App.Timers
  alias App.Tools.Timers, as: Tool
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "a@x.com", name: "Alice"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, u} = Users.upsert_allowed("a@x.com")
    %{user: u}
  end

  defp ctx(user),
    do: %{session_id: to_string(user.id), user_id: user.id, config: App.Config.default()}

  defp no_user, do: %{session_id: "x", user_id: nil, config: App.Config.default()}

  test "declares set_timer, list_timers, cancel_timer and is registered" do
    assert Enum.map(Tool.declarations(), & &1.name) == ~w(set_timer list_timers cancel_timer)
    assert Tool in App.Config.default().tools
  end

  test "its prompt fragment teaches timers vs reminders and is advertised" do
    p = Tool.prompt()
    assert p =~ "set_timer"
    assert p =~ "reminder"
    assert App.Tools.prompt_block(App.Config.default()) =~ p
  end

  describe "set_timer" do
    test "starts a labelled timer and reads back friendly fields", %{user: user} do
      assert {:ok, res} =
               Tool.execute(
                 "set_timer",
                 %{"duration_seconds" => 600, "label" => "pasta"},
                 ctx(user)
               )

      assert res.label == "pasta"
      assert res.duration == "10 min"
      assert res.ends_at_local =~ ~r/^(tomorrow )?\d{1,2}:\d{2} (AM|PM)$/
      assert [%{label: "pasta", duration_ms: 600_000}] = Timers.list_active(user.id)
      assert Jason.encode!(res)
    end

    test "accepts an integer-valued float (JSON numbers)", %{user: user} do
      assert {:ok, %{duration: "1 min 30 s"}} =
               Tool.execute("set_timer", %{"duration_seconds" => 90.0}, ctx(user))
    end

    test "refuses a missing or out-of-range duration with an explanation", %{user: user} do
      for args <- [
            %{},
            %{"duration_seconds" => 0},
            %{"duration_seconds" => 86_401},
            %{"duration_seconds" => "ten"}
          ] do
        assert {:error, msg} = Tool.execute("set_timer", args, ctx(user))
        assert is_binary(msg) and msg =~ "24 hours"
      end

      assert Timers.list_active(user.id) == []
    end

    test "with no user session it narrates instead of saving" do
      assert {:ok, %{note: note}} =
               Tool.execute("set_timer", %{"duration_seconds" => 60}, no_user())

      assert note =~ "no user session"
    end
  end

  describe "list_timers" do
    test "lists active timers with remaining time", %{user: user} do
      {:ok, _} = Timers.create(user.id, 600, "pasta")
      {:ok, r} = Timers.create(user.id, 60)
      {:ok, _} = Timers.fire(r.id)

      assert {:ok, %{count: 2, timers: [ringing, running]}} =
               Tool.execute("list_timers", %{}, ctx(user))

      assert ringing.state == "ringing"
      assert ringing.remaining == "0 s"
      assert running.label == "pasta"
      assert running.remaining =~ ~r/^(9 min \d{1,2} s|10 min)$/
      assert Jason.encode!(%{timers: [ringing, running]})
    end

    test "none running says so", %{user: user} do
      assert {:ok, %{count: 0, timers: [], note: _}} =
               Tool.execute("list_timers", %{}, ctx(user))
    end
  end

  describe "cancel_timer" do
    test "by label", %{user: user} do
      {:ok, _} = Timers.create(user.id, 600, "pasta")
      {:ok, _} = Timers.create(user.id, 300, "eggs")

      assert {:ok, %{cancelled: [%{label: "pasta"}]}} =
               Tool.execute("cancel_timer", %{"label" => "pasta timer"}, ctx(user))

      assert [%{label: "eggs"}] = Timers.list_active(user.id)
    end

    test "all", %{user: user} do
      {:ok, _} = Timers.create(user.id, 600, "pasta")
      {:ok, _} = Timers.create(user.id, 300, "eggs")

      assert {:ok, %{cancelled: cancelled}} =
               Tool.execute("cancel_timer", %{"all" => true}, ctx(user))

      assert length(cancelled) == 2
      assert Timers.list_active(user.id) == []
    end

    test "neither label nor all, exactly one timer: cancels it", %{user: user} do
      {:ok, _} = Timers.create(user.id, 600)
      assert {:ok, %{cancelled: [_]}} = Tool.execute("cancel_timer", %{}, ctx(user))
      assert Timers.list_active(user.id) == []
    end

    test "neither, one RINGING among several: silences the ringing one", %{user: user} do
      {:ok, _} = Timers.create(user.id, 600, "pasta")
      {:ok, r} = Timers.create(user.id, 60, "eggs")
      {:ok, _} = Timers.fire(r.id)

      assert {:ok, %{cancelled: [%{label: "eggs"}]}} =
               Tool.execute("cancel_timer", %{}, ctx(user))

      assert [%{label: "pasta", state: "running"}] = Timers.list_active(user.id)
    end

    test "neither, several running: asks which", %{user: user} do
      {:ok, _} = Timers.create(user.id, 600, "pasta")
      {:ok, _} = Timers.create(user.id, 300, "eggs")

      assert {:ok, %{ambiguous: true, note: note, timers: timers}} =
               Tool.execute("cancel_timer", %{}, ctx(user))

      assert note =~ "which"
      assert length(timers) == 2
      assert length(Timers.list_active(user.id)) == 2
    end

    test "an ambiguous label asks which; an unknown one says nothing matched", %{user: user} do
      {:ok, _} = Timers.create(user.id, 600, "pasta water")
      {:ok, _} = Timers.create(user.id, 300, "pasta sauce")

      assert {:ok, %{ambiguous: true, timers: [_, _]}} =
               Tool.execute("cancel_timer", %{"label" => "pasta"}, ctx(user))

      assert {:ok, %{note: note}} =
               Tool.execute("cancel_timer", %{"label" => "eggs"}, ctx(user))

      assert note =~ "eggs"
    end

    test "nothing running", %{user: user} do
      assert {:ok, %{note: note}} = Tool.execute("cancel_timer", %{}, ctx(user))
      assert note =~ "no timers"
    end
  end

  describe "formatting" do
    test "human durations" do
      assert Tool.human_ms(600_000) == "10 min"
      assert Tool.human_ms(581_000) == "9 min 41 s"
      assert Tool.human_ms(580_200) == "9 min 41 s", "remaining rounds UP to the next second"
      assert Tool.human_ms(45_000) == "45 s"
      assert Tool.human_ms(0) == "0 s"
      assert Tool.human_ms(5_400_000) == "1 h 30 min"
      assert Tool.human_ms(3_600_000) == "1 h"
      assert Tool.human_ms(3_605_000) == "1 h 1 min"
    end
  end
end
