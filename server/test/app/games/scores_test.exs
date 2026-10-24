defmodule App.Games.ScoresTest do
  use ExUnit.Case, async: true

  alias App.Games.Scores

  # The application's own Scores process; each test plays under its own owner key.
  defp owner, do: {:test, make_ref()}

  test "it runs under the application supervisor" do
    assert Process.whereis(Scores)
  end

  test "add accumulates, and a new player starts from zero" do
    o = owner()
    assert {:ok, %{name: "Sam", score: 3}} = Scores.add(o, "Sam", 3)
    assert {:ok, %{name: "Sam", score: 5}} = Scores.add(o, "Sam", 2)
    assert {:ok, %{name: "Ana", score: -1}} = Scores.add(o, "Ana", -1)
    assert Scores.board(o) == [%{name: "Sam", score: 5}, %{name: "Ana", score: -1}]
  end

  test "names match case-insensitively and keep the first spelling" do
    o = owner()
    Scores.add(o, "Sam", 1)
    assert {:ok, %{name: "Sam", score: 3}} = Scores.add(o, "  SAM ", 2)
    assert {:ok, %{name: "Sam", score: 10}} = Scores.set(o, "sam", 10)
    assert Scores.board(o) == [%{name: "Sam", score: 10}]
  end

  test "the board is by score, leader first; ties keep the order players joined" do
    o = owner()
    Scores.add(o, "Joe", 2)
    Scores.add(o, "Ana", 7)
    Scores.add(o, "Sam", 2)
    assert Enum.map(Scores.board(o), & &1.name) == ~w(Ana Joe Sam)
  end

  test "set overwrites a score and adds a player who wasn't there" do
    o = owner()
    Scores.add(o, "Sam", 4)
    assert {:ok, %{score: 0}} = Scores.set(o, "Sam", 0)
    assert {:ok, %{name: "Kim", score: 12}} = Scores.set(o, "Kim", 12)
    assert Scores.board(o) == [%{name: "Kim", score: 12}, %{name: "Sam", score: 0}]
  end

  test "reset clears only this owner's board" do
    a = owner()
    b = owner()
    Scores.add(a, "Sam", 3)
    Scores.add(b, "Sam", 9)
    assert Scores.reset(a) == :ok
    assert Scores.board(a) == []
    assert Scores.board(b) == [%{name: "Sam", score: 9}]
  end

  test "an owner with no game has an empty board" do
    assert Scores.board(owner()) == []
  end

  test "a board holds at most 20 players" do
    o = owner()
    for n <- 1..20, do: {:ok, _} = Scores.add(o, "P#{n}", 1)
    assert {:error, msg} = Scores.add(o, "P21", 1)
    assert msg =~ "20"
    # an existing player still scores
    assert {:ok, %{score: 2}} = Scores.add(o, "p1", 1)
  end

  test "a snapshot's version orders boards: a higher one saw every earlier write" do
    o = owner()
    Scores.add(o, "Sam", 3)
    {board, v1} = Scores.snapshot(o)
    assert board == [%{name: "Sam", score: 3}]
    Scores.add(o, "Ana", 5)
    {board, v2} = Scores.snapshot(o)
    assert board == [%{name: "Ana", score: 5}, %{name: "Sam", score: 3}]
    assert is_integer(v1) and v2 > v1

    # a reset board is still newer than the one before it
    Scores.reset(o)
    assert {[], v3} = Scores.snapshot(o)
    assert v3 > v2
  end

  test "concurrent adds (parallel tool calls) all land" do
    o = owner()

    1..20
    |> Task.async_stream(fn _ -> Scores.add(o, "Sam", 1) end, max_concurrency: 20)
    |> Stream.run()

    assert Scores.board(o) == [%{name: "Sam", score: 20}]
  end
end
