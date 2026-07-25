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

  test "for: household with the gate OFF -> personal fallback to the session user" do
    got = Target.resolve("household", opts(%{gate_on: false, active_scope: :household}))
    assert %{user_id: 1, household: false, assigned: "you"} = got
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
