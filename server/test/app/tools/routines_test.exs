defmodule App.Tools.RoutinesTest do
  use App.DataCase, async: false
  alias App.Tools.Routines, as: Tool
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

  @good_night %{
    "name" => "good night",
    "triggers" => ["good night", "bedtime"],
    "steps" =>
      "Turn off the downstairs lights. Set the thermostat to 68. " <>
        "Tell me the first event on my calendar tomorrow."
  }

  describe "save_routine" do
    test "saves and reads back name, triggers and steps", %{user: user} do
      assert {:ok, r} = Tool.execute("save_routine", @good_night, ctx(user))

      assert r.saved == "good night"
      assert r.triggers == ["good night", "bedtime"]
      assert r.steps =~ "thermostat to 68"
      assert r.replaced == false
      assert App.Routines.get(user.id, "bedtime")
    end

    test "saving an existing name reports replaced", %{user: user} do
      {:ok, _} = Tool.execute("save_routine", @good_night, ctx(user))

      assert {:ok, %{replaced: true}} =
               Tool.execute(
                 "save_routine",
                 %{"name" => "Good Night", "steps" => "Lock up."},
                 ctx(user)
               )

      assert [%{steps: "Lock up."}] = App.Routines.list(user.id)
    end

    test "a trigger another routine owns is refused with a narrated note", %{user: user} do
      {:ok, _} = Tool.execute("save_routine", @good_night, ctx(user))

      assert {:ok, %{saved: false, note: note}} =
               Tool.execute(
                 "save_routine",
                 %{"name" => "kids down", "triggers" => ["bedtime"], "steps" => "Dim lights."},
                 ctx(user)
               )

      assert note =~ "bedtime"
      assert note =~ "good night"
    end

    test "steps over the cap are refused with a narrated note", %{user: user} do
      assert {:ok, %{saved: false, note: note}} =
               Tool.execute(
                 "save_routine",
                 %{"name" => "long", "steps" => String.duplicate("a", 2_001)},
                 ctx(user)
               )

      assert note =~ "2,000"
    end

    test "a trigger that starts with Henry's sleep or stop words is dropped and flagged",
         %{user: user} do
      assert {:ok, r} =
               Tool.execute(
                 "save_routine",
                 %{
                   "name" => "leaving",
                   "triggers" => ["lock up", "stop everything", "I'm heading out"],
                   "steps" => "Turn off every light."
                 },
                 ctx(user)
               )

      assert r.triggers == ["I'm heading out"]
      assert r.unreachable == ["lock up", "stop everything"]
      assert r.note =~ "lock up"
    end

    test "'good night' is NOT swallowed by the sleep/stop words" do
      cfg = App.Config.default()
      assert Tool.swallowed("good night", cfg) == nil
      assert Tool.swallowed("goodnight", cfg) == nil
      assert Tool.swallowed("bedtime", cfg) == nil
      assert Tool.swallowed("go to sleep", cfg) == :sleep
      assert Tool.swallowed("lock up", cfg) == :sleep
      assert Tool.swallowed("wait for me", cfg) == :stop
    end

    test "missing name or steps -> missing_args", %{user: user} do
      assert {:error, :missing_args} =
               Tool.execute("save_routine", %{"name" => "x"}, ctx(user))

      assert {:error, :missing_args} =
               Tool.execute("save_routine", %{"steps" => "x"}, ctx(user))
    end

    test "with no user session returns a narrated note" do
      assert {:ok, %{note: note}} = Tool.execute("save_routine", @good_night, no_session())
      assert note =~ "no user session"
    end
  end

  describe "run_routine" do
    test "returns the steps and instructions to carry them out, and marks it run",
         %{user: user} do
      {:ok, _} = Tool.execute("save_routine", @good_night, ctx(user))

      assert {:ok, r} = Tool.execute("run_routine", %{"name" => "Bedtime!"}, ctx(user))
      assert r.name == "good night"
      assert r.steps =~ "downstairs lights"
      assert r.instructions =~ "Carry out every step now"
      assert r.instructions =~ "ONE short summary"

      assert %DateTime{} = App.Routines.get(user.id, "good night").last_run_at
    end

    test "unknown routine -> note listing what does exist", %{user: user} do
      {:ok, _} = Tool.execute("save_routine", @good_night, ctx(user))

      assert {:ok, %{note: note, routines: ["good night"]}} =
               Tool.execute("run_routine", %{"name" => "good morning"}, ctx(user))

      assert note =~ "good morning"
    end

    test "never runs another user's routine", %{user: user, other: other} do
      {:ok, _} = Tool.execute("save_routine", @good_night, ctx(user))

      assert {:ok, %{note: _, routines: []}} =
               Tool.execute("run_routine", %{"name" => "good night"}, ctx(other))
    end

    test "with no user session returns a narrated note" do
      assert {:ok, %{note: _}} = Tool.execute("run_routine", %{"name" => "x"}, no_session())
    end
  end

  describe "list_routines" do
    test "reads back every routine with its steps", %{user: user} do
      {:ok, _} = Tool.execute("save_routine", @good_night, ctx(user))

      assert {:ok, %{routines: [r]}} = Tool.execute("list_routines", %{}, ctx(user))
      assert r.name == "good night"
      assert r.triggers == ["good night", "bedtime"]
      assert r.steps =~ "thermostat"
      assert r.last_run == nil
    end

    test "none saved -> benign note", %{user: user} do
      assert {:ok, %{routines: [], note: _}} = Tool.execute("list_routines", %{}, ctx(user))
    end

    test "with no user session returns a narrated note" do
      assert {:ok, %{note: _}} = Tool.execute("list_routines", %{}, no_session())
    end
  end

  describe "delete_routine" do
    test "deletes by name", %{user: user} do
      {:ok, _} = Tool.execute("save_routine", @good_night, ctx(user))

      assert {:ok, %{deleted: "good night"}} =
               Tool.execute("delete_routine", %{"name" => "Good night"}, ctx(user))

      assert App.Routines.list(user.id) == []
    end

    test "unknown -> benign note", %{user: user} do
      assert {:ok, %{note: _}} =
               Tool.execute("delete_routine", %{"name" => "nope"}, ctx(user))
    end

    test "with no user session returns a narrated note" do
      assert {:ok, %{note: _}} = Tool.execute("delete_routine", %{"name" => "x"}, no_session())
    end
  end

  test "declarations expose the four functions" do
    names = Tool.declarations() |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ~w(delete_routine list_routines run_routine save_routine)

    save = Enum.find(Tool.declarations(), &(&1.name == "save_routine"))
    assert save.parameters.required == ["name", "steps"]
    assert save.parameters.properties.triggers.type == "array"
  end

  test "bridge speaks only for run_routine" do
    assert [_ | _] = Tool.bridge("run_routine")
    assert Tool.bridge("save_routine") == []
    assert Tool.bridge("list_routines") == []
  end

  test "prompt/0 teaches confirm-before-save and run-first-then-every-step" do
    p = Tool.prompt()
    assert p =~ "save_routine"
    assert p =~ ~r/confirm/i
    assert p =~ "run_routine FIRST"
    assert p =~ ~r/never invent/i
    refute String.starts_with?(p, " ")
  end

  test "registered in the default config" do
    assert Tool in App.Config.default().tools
  end
end
