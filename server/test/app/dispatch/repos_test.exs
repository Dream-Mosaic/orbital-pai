defmodule App.Dispatch.ReposTest do
  use ExUnit.Case, async: true

  alias App.Dispatch.Repos

  @fixture "test/fixtures/dispatch/boards.json" |> File.read!() |> Jason.decode!()

  defp repos do
    for r <- @fixture["repos"] do
      %{
        name: r["name"],
        full_name: r["full_name"],
        default_branch: r["default_branch"],
        open_issues: r["open_issues_count"]
      }
    end
  end

  defp name({:ok, repo}), do: repo.name

  test "resolves spoken names against the fixture" do
    for {phrase, want} <- [
          {"unwritten chronicles", "unwritten-chronicles"},
          {"the chronicles app", "unwritten-chronicles"},
          {"chronicals", "unwritten-chronicles"},
          {"Henry", "personal-assistant"},
          {"you", "personal-assistant"},
          {"garden", "garden-planner"}
        ] do
      assert name(Repos.resolve(repos(), phrase)) == want, phrase
    end
  end

  test "no match returns the candidates" do
    assert {:none, list} = Repos.resolve(repos(), "zzz")
    assert length(list) == length(repos())
  end

  test "ambiguous when several repos fit" do
    list = [
      %{name: "garden-planner", full_name: "k/garden-planner"},
      %{name: "garden-journal", full_name: "k/garden-journal"}
    ]

    assert {:ambiguous, [_, _]} = Repos.resolve(list, "garden")
  end

  test "custom aliases" do
    assert {:ok, %{name: "homelab"}} =
             Repos.resolve(repos(), "the house", %{"the house" => "homelab"})
  end

  test "empty phrase is none" do
    assert {:none, _} = Repos.resolve(repos(), "the app")
  end

  test "typo boundary: distance 2 on a word under 8 letters is rejected" do
    # "garten" is 1 away from "garden"; "gardenxx" is 2 away but "garden" is only 6 letters.
    assert {:ok, %{name: "garden-planner"}} = Repos.resolve(repos(), "garten")
    assert {:none, _} = Repos.resolve(repos(), "gartxn")
  end
end
