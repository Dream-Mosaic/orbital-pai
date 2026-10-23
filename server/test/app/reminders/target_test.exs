defmodule App.Reminders.TargetTest do
  use ExUnit.Case, async: true
  alias App.Reminders.Target

  # Injected users so the resolver is pure (no DB): mimic App.Users structs.
  @users [%{id: 1, name: "David"}, %{id: 2, name: "Tanya"}]
  defp opts(over \\ %{}),
    do:
      Map.merge(
        %{session_user_id: 1, active_scope: :personal, gate_on: true, users: @users},
        over
      )

  test "default self, personal scope -> personal to the session user" do
    assert %{user_id: 1, household: false, assigned: "you"} = Target.resolve(nil, opts())
    assert %{user_id: 1, household: false} = Target.resolve("self", opts())
  end

  test "default self while active_scope is household (gate on) -> household" do
    got = Target.resolve("self", opts(%{active_scope: :household}))
    assert %{user_id: 1, household: true, assigned: "the household"} = got
  end

  test "for: household (gate on) -> household regardless of scope" do
    assert %{household: true, assigned: "the household"} = Target.resolve("household", opts())
  end

  test "for: household with the gate OFF on a personal device -> personal fallback" do
    got = Target.resolve("household", opts(%{gate_on: false}))
    assert %{user_id: 1, household: false, assigned: "you"} = got
  end

  # Phase 4 (spec 2026-10-23-wall-tablet-design): a shared household device is itself the
  # opt-in for household scope, so household scope needs no gate for self or household words.
  describe "household scope (the bound device is a shared household device)" do
    test "self/me/unspecified -> household, even with the gate OFF" do
      for word <- [nil, "", "self", "me", "myself"] do
        got = Target.resolve(word, opts(%{gate_on: false, active_scope: :household}))
        assert %{user_id: 1, household: true, assigned: "the household"} = got
      end
    end

    test "household words -> household, even with the gate OFF" do
      for word <- ["household", "us", "we", "both", "the house", "the household"] do
        got = Target.resolve(word, opts(%{gate_on: false, active_scope: :household}))
        assert %{household: true, assigned: "the household"} = got
      end
    end

    test "a named person is resolved exactly as on a personal device" do
      for gate <- [true, false] do
        assert Target.resolve("tanya", opts(%{gate_on: gate, active_scope: :household})) ==
                 Target.resolve("tanya", opts(%{gate_on: gate}))
      end
    end
  end

  test "for a known name (case-insensitive) -> that person, personal" do
    assert %{user_id: 2, household: false, assigned: "Tanya"} = Target.resolve("tanya", opts())
  end

  test "unknown name -> PERSONAL to the session user (never household), labeled honestly" do
    got = Target.resolve("Alex", opts(%{active_scope: :household}))
    assert got.user_id == 1
    assert got.household == false
    assert got.assigned =~ "you"
  end
end
