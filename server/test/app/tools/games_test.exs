defmodule App.Tools.GamesTest do
  use ExUnit.Case, async: true

  alias App.Tools.Games, as: Tool

  # A fresh user per test (the scoreboard is keyed by user id) and a fixed seed, so every
  # roll, flip and pick below is the same on every run.
  defp ctx(opts \\ []) do
    %{
      session_id: "s",
      user_id: Keyword.get(opts, :user_id, System.unique_integer([:positive])),
      config: App.Config.default(),
      seed: Keyword.get(opts, :seed, 42)
    }
  end

  test "declares the four game tools, always on (no toolkit hop)" do
    assert Enum.map(Tool.declarations(), & &1.name) ==
             ~w(roll_dice flip_coin pick_one keep_score)

    assert Tool in App.Config.default().tools
  end

  test "its prompt says never to invent a result, and is advertised" do
    p = Tool.prompt()
    assert p =~ "Never invent a roll, flip, pick or score"
    assert String.length(p) < 500
    assert App.Tools.prompt_block(App.Config.default()) =~ p
  end

  test "nothing here is cached: a re-roll must really re-roll" do
    Code.ensure_loaded!(Tool)
    refute function_exported?(Tool, :cache_ttl, 1)
  end

  describe "roll_dice" do
    test "returns each die, the modifier and the total" do
      assert {:ok, r} = Tool.execute("roll_dice", %{"notation" => "3d8+2"}, ctx())
      assert r.notation == "3d8+2"
      assert r.sides == 8
      assert r.modifier == 2
      assert length(r.dice) == 3
      assert Enum.all?(r.dice, &(&1 in 1..8))
      assert r.total == Enum.sum(r.dice) + 2
      assert Jason.encode!(r)
    end

    test "the same seed rolls the same dice; another seed doesn't" do
      {:ok, a} = Tool.execute("roll_dice", %{"notation" => "10d20"}, ctx(seed: 1))
      {:ok, b} = Tool.execute("roll_dice", %{"notation" => "10d20"}, ctx(seed: 1))
      {:ok, c} = Tool.execute("roll_dice", %{"notation" => "10d20"}, ctx(seed: 2))
      assert a == b
      assert a.dice != c.dice
    end

    test "normalizes the notation it read back" do
      assert {:ok, %{notation: "d20", total: t, dice: [t]}} =
               Tool.execute("roll_dice", %{"notation" => "1D20"}, ctx())

      assert {:ok, %{notation: "2d6-1"}} =
               Tool.execute("roll_dice", %{"notation" => "2 d6 - 1"}, ctx())
    end

    test "bad notation and limits come back as sentences" do
      assert {:error, msg} = Tool.execute("roll_dice", %{"notation" => "a bunch"}, ctx())
      assert msg =~ "2d6"
      assert {:error, msg} = Tool.execute("roll_dice", %{"notation" => "20d6"}, ctx())
      assert msg =~ "10 dice"
      assert {:error, _} = Tool.execute("roll_dice", %{}, ctx())
    end
  end

  describe "flip_coin" do
    test "one flip by default" do
      assert {:ok, %{flips: [side], heads: h, tails: t}} = Tool.execute("flip_coin", %{}, ctx())
      assert side in ["heads", "tails"]
      assert h + t == 1
    end

    test "several flips, tallied" do
      assert {:ok, r} = Tool.execute("flip_coin", %{"count" => 10}, ctx())
      assert length(r.flips) == 10
      assert r.heads == Enum.count(r.flips, &(&1 == "heads"))
      assert r.tails == 10 - r.heads
      assert {:ok, ^r} = Tool.execute("flip_coin", %{"count" => 10.0}, ctx())
    end

    test "1 to 10 flips" do
      for n <- [0, 11, "three"] do
        assert {:error, msg} = Tool.execute("flip_coin", %{"count" => n}, ctx())
        assert msg =~ "1 to 10"
      end
    end
  end

  describe "pick_one" do
    test "picks one of the options" do
      opts = ~w(Sam Ana Joe)

      assert {:ok, %{picked: [p], options: ^opts}} =
               Tool.execute("pick_one", %{"options" => opts}, ctx())

      assert p in opts
    end

    test "picks several, all different" do
      opts = ~w(Sam Ana Joe Kim)

      assert {:ok, %{picked: picked}} =
               Tool.execute("pick_one", %{"options" => opts, "count" => 2}, ctx())

      assert length(Enum.uniq(picked)) == 2
      assert Enum.all?(picked, &(&1 in opts))
    end

    test "shuffle returns every option in a turn order" do
      opts = ~w(Sam Ana Joe Kim)

      assert {:ok, %{order: order}} =
               Tool.execute("pick_one", %{"options" => opts, "shuffle" => true}, ctx())

      assert Enum.sort(order) == Enum.sort(opts)

      # asking for as many as there are options is a turn order too
      assert {:ok, %{order: ^order}} =
               Tool.execute("pick_one", %{"options" => opts, "count" => 4}, ctx())
    end

    test "the same seed picks the same" do
      args = %{"options" => ~w(a b c d e f g), "shuffle" => true}

      assert Tool.execute("pick_one", args, ctx(seed: 9)) ==
               Tool.execute("pick_one", args, ctx(seed: 9))
    end

    test "trims, drops blanks and case-insensitive repeats" do
      # the first spelling of a repeat is the one kept
      assert {:ok, %{options: ["Sam", "Ana"]}} =
               Tool.execute("pick_one", %{"options" => [" Sam ", "", "Ana", "ana", "sam"]}, ctx())
    end

    test "needs two options, at most 20, and a sensible count" do
      assert {:error, msg} = Tool.execute("pick_one", %{"options" => ["Sam"]}, ctx())
      assert msg =~ "two"
      assert {:error, _} = Tool.execute("pick_one", %{}, ctx())
      assert {:error, _} = Tool.execute("pick_one", %{"options" => "Sam, Ana"}, ctx())

      many = for n <- 1..21, do: "p#{n}"
      assert {:error, msg} = Tool.execute("pick_one", %{"options" => many}, ctx())
      assert msg =~ "20"

      assert {:error, msg} =
               Tool.execute("pick_one", %{"options" => ~w(a b c), "count" => 5}, ctx())

      assert msg =~ "1 to 3"
      assert {:error, _} = Tool.execute("pick_one", %{"options" => ~w(a b), "count" => 0}, ctx())
    end
  end

  describe "keep_score" do
    test "add, set, show: the board comes back leader first" do
      c = ctx()

      assert {:ok, r} =
               Tool.execute(
                 "keep_score",
                 %{"action" => "add", "player" => "Sam", "points" => 3},
                 c
               )

      assert %{action: "add", player: "Sam", points: 3, score: 3, leaders: ["Sam"]} = r

      Tool.execute("keep_score", %{"action" => "add", "player" => "Ana", "points" => 5}, c)

      assert {:ok, %{player: "Sam", score: 10}} =
               Tool.execute(
                 "keep_score",
                 %{"action" => "set", "player" => "sam", "points" => 10},
                 c
               )

      assert {:ok, show} = Tool.execute("keep_score", %{"action" => "show"}, c)

      assert show.scores == [%{player: "Sam", score: 10}, %{player: "Ana", score: 5}]
      assert show.leaders == ["Sam"]
      assert Jason.encode!(show)
    end

    test "a tie at the top names every leader" do
      c = ctx()
      Tool.execute("keep_score", %{"action" => "add", "player" => "Sam", "points" => 2}, c)
      Tool.execute("keep_score", %{"action" => "add", "player" => "Ana", "points" => 2}, c)

      assert {:ok, %{leaders: ["Sam", "Ana"]}} =
               Tool.execute("keep_score", %{"action" => "show"}, c)
    end

    test "show with no game is an empty board" do
      assert {:ok, %{scores: [], leaders: [], note: note}} =
               Tool.execute("keep_score", %{"action" => "show"}, ctx())

      assert note =~ "no scores"
    end

    test "reset clears the board" do
      c = ctx()
      Tool.execute("keep_score", %{"action" => "add", "player" => "Sam", "points" => 2}, c)
      assert {:ok, %{scores: []}} = Tool.execute("keep_score", %{"action" => "reset"}, c)
      assert {:ok, %{scores: []}} = Tool.execute("keep_score", %{"action" => "show"}, c)
    end

    test "each user keeps their own board" do
      a = ctx(user_id: System.unique_integer([:positive]))
      b = ctx(user_id: System.unique_integer([:positive]))
      Tool.execute("keep_score", %{"action" => "add", "player" => "Sam", "points" => 4}, a)
      Tool.execute("keep_score", %{"action" => "add", "player" => "Joe", "points" => 1}, b)

      assert {:ok, %{scores: [%{player: "Sam", score: 4}]}} =
               Tool.execute("keep_score", %{"action" => "show"}, a)

      assert {:ok, %{scores: [%{player: "Joe", score: 1}]}} =
               Tool.execute("keep_score", %{"action" => "show"}, b)

      Tool.execute("keep_score", %{"action" => "reset"}, b)

      assert {:ok, %{scores: [_]}} = Tool.execute("keep_score", %{"action" => "show"}, a)
    end

    test "with no signed-in user it still keeps score, for the session" do
      c = %{ctx() | user_id: nil, session_id: "anon-#{System.unique_integer([:positive])}"}
      Tool.execute("keep_score", %{"action" => "add", "player" => "Sam", "points" => 1}, c)

      assert {:ok, %{scores: [%{player: "Sam"}]}} =
               Tool.execute("keep_score", %{"action" => "show"}, c)
    end

    test "points are whole numbers; integral floats are fine; a negative add takes away" do
      c = ctx()

      assert {:ok, %{score: 3}} =
               Tool.execute(
                 "keep_score",
                 %{"action" => "add", "player" => "Sam", "points" => 3.0},
                 c
               )

      assert {:ok, %{score: 1}} =
               Tool.execute(
                 "keep_score",
                 %{"action" => "add", "player" => "Sam", "points" => -2},
                 c
               )

      for points <- [nil, 1.5, "two"] do
        assert {:error, msg} =
                 Tool.execute(
                   "keep_score",
                   %{"action" => "add", "player" => "Sam", "points" => points},
                   c
                 )

        assert msg =~ "whole number"
      end
    end

    test "add and set need a player; the action must be known" do
      c = ctx()

      assert {:error, msg} =
               Tool.execute("keep_score", %{"action" => "add", "points" => 2}, c)

      assert msg =~ "player"

      assert {:error, _} =
               Tool.execute(
                 "keep_score",
                 %{"action" => "add", "player" => "  ", "points" => 2},
                 c
               )

      assert {:error, msg} = Tool.execute("keep_score", %{"action" => "undo"}, c)
      assert msg =~ "add, set, show or reset"
    end
  end
end
