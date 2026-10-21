defmodule App.Dispatch.TriageTest do
  use ExUnit.Case, async: true

  alias App.Dispatch.{Forge, Triage}

  @fixture "test/fixtures/dispatch/boards.json" |> File.read!() |> Jason.decode!()
  @ctx %{design_gated?: false, active_job?: false, open_pr?: false}

  defp issue(repo, n) do
    @fixture["issues"][repo]
    |> Enum.find(&(&1["number"] == n))
    |> Forge.normalize_issue()
  end

  test "fixture-driven classification" do
    assert Triage.classify(issue("unwritten-chronicles", 31), @ctx) == {:candidate, :bug}
    assert {:skip, "idea"} = Triage.classify(issue("unwritten-chronicles", 32), @ctx)
    assert {:skip, "idea"} = Triage.classify(issue("personal-assistant", 25), @ctx)
    assert Triage.classify(issue("personal-assistant", 23), @ctx) == {:candidate, :bug}
    assert Triage.classify(issue("personal-assistant", 24), @ctx) == {:candidate, :debt}
    assert Triage.classify(issue("unwritten-chronicles", 16), @ctx) == {:candidate, :feature}
  end

  test "a feature in a design-gated repo is a design candidate; a bug is not" do
    gated = %{@ctx | design_gated?: true}
    assert Triage.classify(issue("personal-assistant", 17), gated) == {:candidate, :design}
    assert Triage.classify(issue("personal-assistant", 23), gated) == {:candidate, :bug}
  end

  test "work_kind/2 is the kind by labels alone, whatever would skip the issue" do
    assert Triage.work_kind(issue("personal-assistant", 23), true) == :bug
    assert Triage.work_kind(issue("personal-assistant", 24), true) == :debt
    assert Triage.work_kind(issue("personal-assistant", 17), true) == :design
    assert Triage.work_kind(issue("personal-assistant", 17), false) == :feature
    # An idea would be skipped on the board, but if David starts it anyway, it's feature work.
    assert Triage.work_kind(issue("personal-assistant", 25), true) == :design
  end

  test "empty body, open PR, active job, pull requests and pull requests" do
    base = %{number: 1, title: "t", labels: ["bug"], body: "x", pull_request: false}
    assert {:skip, "no description"} = Triage.classify(%{base | body: "  \n"}, @ctx)
    assert {:skip, "no description"} = Triage.classify(%{base | body: nil}, @ctx)
    assert {:skip, "PR already open"} = Triage.classify(base, %{@ctx | open_pr?: true})
    assert {:skip, "job already active"} = Triage.classify(base, %{@ctx | active_job?: true})
    assert {:skip, "is a pull request"} = Triage.classify(%{base | pull_request: true}, @ctx)
  end

  test "no type label: a real body makes it a feature (design when gated)" do
    base = %{number: 1, title: "t", labels: [], body: "x", pull_request: false}
    gated = %{@ctx | design_gated?: true}
    assert Triage.classify(base, @ctx) == {:candidate, :feature}
    assert Triage.classify(%{base | labels: ["native", "server"]}, @ctx) == {:candidate, :feature}
    assert Triage.classify(%{base | labels: ["native"]}, gated) == {:candidate, :design}
  end

  test "order: bug, debt, feature, design; newest first" do
    items = [
      %{kind: :design, number: 9},
      %{kind: :feature, number: 8},
      %{kind: :bug, number: 1},
      %{kind: :debt, number: 5},
      %{kind: :bug, number: 7}
    ]

    assert Enum.map(Triage.order(items), & &1.number) == [7, 1, 5, 8, 9]
  end
end
