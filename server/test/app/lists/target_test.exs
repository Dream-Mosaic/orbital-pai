defmodule App.Lists.TargetTest do
  use ExUnit.Case, async: true
  alias App.Lists.Target

  @users [%{id: 1, name: "David"}, %{id: 2, name: "Tanya"}]
  defp opts(over \\ %{}),
    do: Map.merge(%{session_user_id: 1, gate_on: true, users: @users}, over)

  test "default (nil) -> household, unconditionally (shared by default)" do
    assert %{user_id: 1, household: true, assigned: "the household"} = Target.resolve(nil, opts())
    # NOT gated — unlike reminders, the household default holds even with the gate off.
    assert %{household: true, assigned: "the household"} =
             Target.resolve(nil, opts(%{gate_on: false}))
  end

  test "empty string -> household" do
    assert %{household: true} = Target.resolve("", opts())
  end

  test "household words -> household" do
    for word <- ["household", "us", "we", "both", "the house", "the household"] do
      assert %{household: true, assigned: "the household"} = Target.resolve(word, opts())
    end
  end

  test "personal words -> personal to the session user" do
    for word <- ["self", "my", "me", "mine", "myself", "personal"] do
      assert %{user_id: 1, household: false, assigned: "you"} = Target.resolve(word, opts())
    end
  end

  test "a known name (case-insensitive) -> that person, personal, when the gate is ON" do
    assert %{user_id: 2, household: false, assigned: "Tanya"} = Target.resolve("tanya", opts())
  end

  test "a known name falls back to session-personal when the gate is OFF" do
    got = Target.resolve("tanya", opts(%{gate_on: false}))
    assert %{user_id: 1, household: false, assigned: "you"} = got
  end

  test "an unknown name -> falls back to the session user, personal (never silently household)" do
    got = Target.resolve("Alex", opts())
    assert got.user_id == 1
    assert got.household == false
    assert got.assigned == "you"
  end

  # Phase 4 (spec 2026-10-23-wall-tablet-design): on a shared household device "my"/"me" can't
  # name whoever is speaking, so personal words land on the household too. A named person is
  # still gated by household_named_targets.
  describe "household scope (the bound device is a shared household device)" do
    test "personal words -> household" do
      for word <- ["self", "my", "me", "mine", "myself", "personal"] do
        got = Target.resolve(word, opts(%{active_scope: :household}))
        assert %{user_id: 1, household: true, assigned: "the household"} = got
      end
    end

    test "unspecified and household words stay household" do
      for word <- [nil, "", "household", "us"] do
        assert %{household: true} = Target.resolve(word, opts(%{active_scope: :household}))
      end
    end

    test "a named person is still gated" do
      assert %{user_id: 2, household: false, assigned: "Tanya"} =
               Target.resolve("tanya", opts(%{active_scope: :household}))

      assert %{user_id: 1, household: false, assigned: "you"} =
               Target.resolve("tanya", opts(%{gate_on: false, active_scope: :household}))
    end
  end
end
