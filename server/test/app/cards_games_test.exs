defmodule App.CardsGamesTest do
  use ExUnit.Case, async: true

  alias App.Cards
  alias App.Tools.Games, as: Tool

  defp card(name, args, result), do: Cards.from_tool(name, args, result)

  # The tool's own result for these args, so the card is built from exactly what the brain saw.
  defp run(name, args, ctx \\ %{session_id: "s", user_id: nil, seed: 42}) do
    {:ok, r} = Tool.execute(name, args, Map.put_new(ctx, :config, App.Config.default()))
    r
  end

  describe "dice" do
    test "each die, the modifier and the total, with the arithmetic spelled out" do
      r = %{notation: "3d8+2", sides: 8, dice: [5, 1, 7], modifier: 2, total: 15}

      assert card("roll_dice", %{"notation" => "3d8+2"}, r) == %{
               type: "dice",
               title: "Rolled 3d8+2",
               dice: [5, 1, 7],
               modifier: "+2",
               total: "15",
               math: "5 + 1 + 7 + 2"
             }
    end

    test "d6 dice are drawn with pips" do
      r = %{notation: "2d6", sides: 6, dice: [3, 4], modifier: 0, total: 7}
      c = card("roll_dice", %{}, r)
      assert c.pips == true
      assert c.total == "7"
      assert c.math == "3 + 4"
      refute Map.has_key?(c, :modifier)
    end

    test "a single die with nothing added is its own total" do
      r = %{notation: "d20", sides: 20, dice: [14], modifier: 0, total: 14}
      assert card("roll_dice", %{}, r) == %{type: "dice", title: "Rolled d20", dice: [14]}
    end

    test "a negative modifier reads with a real minus" do
      r = %{notation: "d6-1", sides: 6, dice: [4], modifier: -1, total: 3}
      c = card("roll_dice", %{}, r)
      assert c.modifier == "−1"
      assert c.math == "4 − 1"
      assert c.total == "3"
    end

    test "from a real roll, and it encodes" do
      c = card("roll_dice", %{"notation" => "2d6"}, run("roll_dice", %{"notation" => "2d6"}))
      assert c.type == "dice"
      assert length(c.dice) == 2
      assert Jason.encode!(c)
    end
  end

  describe "coin" do
    test "one flip" do
      assert card("flip_coin", %{}, %{flips: ["heads"], heads: 1, tails: 0}) == %{
               type: "coin",
               title: "Coin flip",
               flips: [%{side: "heads", label: "Heads", mark: "H"}]
             }
    end

    test "several flips, tallied" do
      c = card("flip_coin", %{}, %{flips: ~w(heads tails heads), heads: 2, tails: 1})
      assert c.title == "3 coin flips"
      assert Enum.map(c.flips, & &1.mark) == ~w(H T H)
      assert c.summary == "2 heads · 1 tail"

      c = card("flip_coin", %{}, %{flips: ~w(tails tails), heads: 0, tails: 2})
      assert c.summary == "2 tails"
    end
  end

  describe "pick" do
    test "the chosen one, highlighted among the options" do
      r = %{options: ~w(Sam Ana Joe), picked: ["Ana"]}

      assert card("pick_one", %{}, r) == %{
               type: "pick",
               title: "Picked",
               headline: "Ana",
               options: [
                 %{label: "Sam", chosen: false},
                 %{label: "Ana", chosen: true},
                 %{label: "Joe", chosen: false}
               ],
               trailing: "1 of 3"
             }
    end

    test "several chosen" do
      r = %{options: ~w(Sam Ana Joe Kim), picked: ~w(Kim Sam)}
      c = card("pick_one", %{}, r)
      assert c.title == "Picked 2"
      assert c.headline == "Kim and Sam"
      assert c.trailing == "2 of 4"
      assert for(%{chosen: true, label: l} <- c.options, do: l) == ~w(Sam Kim)

      c = card("pick_one", %{}, %{options: ~w(a b c d), picked: ~w(c a d)})
      assert c.headline == "c, a and d"
    end

    test "a shuffle is a numbered turn order" do
      r = %{options: ~w(Sam Ana Joe), order: ~w(Joe Sam Ana)}

      assert card("pick_one", %{}, r) == %{
               type: "pick",
               title: "Turn order",
               order: [
                 %{rank: "1", label: "Joe"},
                 %{rank: "2", label: "Sam"},
                 %{rank: "3", label: "Ana"}
               ]
             }
    end
  end

  describe "scoreboard" do
    test "rank, name and points, leader first and highlighted; the change marked" do
      r = %{
        action: "add",
        player: "Ana",
        points: 3,
        score: 8,
        scores: [
          %{player: "Ana", score: 8},
          %{player: "Sam", score: 5},
          %{player: "Joe", score: 5},
          %{player: "Kim", score: -2}
        ],
        leaders: ["Ana"]
      }

      assert card("keep_score", %{"action" => "add"}, r) == %{
               type: "scoreboard",
               slot: "scoreboard",
               title: "Scoreboard",
               trailing: "4 players",
               rows: [
                 %{rank: "1", name: "Ana", points: "8", leader: true, delta: "+3"},
                 %{rank: "2", name: "Sam", points: "5", leader: false},
                 %{rank: "2", name: "Joe", points: "5", leader: false},
                 %{rank: "4", name: "Kim", points: "−2", leader: false}
               ]
             }
    end

    test "a tie at the top lights every leader; an all-square board lights none" do
      r = %{
        action: "show",
        scores: [
          %{player: "Sam", score: 4},
          %{player: "Ana", score: 4},
          %{player: "Joe", score: 1}
        ],
        leaders: ["Sam", "Ana"]
      }

      assert Enum.map(card("keep_score", %{}, r).rows, & &1.leader) == [true, true, false]

      r = %{
        action: "show",
        scores: [%{player: "Sam", score: 0}, %{player: "Ana", score: 0}],
        leaders: ["Sam", "Ana"]
      }

      assert Enum.map(card("keep_score", %{}, r).rows, & &1.leader) == [false, false]
    end

    test "a negative add shows a real minus; set shows no delta; big scores are grouped" do
      base = %{scores: [%{player: "Sam", score: 1200}], leaders: ["Sam"], player: "Sam"}

      [row] = card("keep_score", %{}, Map.merge(base, %{action: "add", points: -2})).rows
      assert row.delta == "−2"
      assert row.points == "1,200"

      [row] = card("keep_score", %{}, Map.merge(base, %{action: "set", points: 1200})).rows
      refute Map.has_key?(row, :delta)
      assert card("keep_score", %{}, Map.put(base, :action, "show")).trailing == "1 player"
    end

    test "a long board shows the top 10 and how many more" do
      scores = for n <- 1..13, do: %{player: "P#{n}", score: 100 - n}
      c = card("keep_score", %{}, %{action: "show", scores: scores, leaders: ["P1"]})
      assert length(c.rows) == 10
      assert c.more == "+3 more"
    end

    test "an empty board (show with no game, reset) is no card" do
      assert card("keep_score", %{}, %{action: "show", scores: [], leaders: [], note: "x"}) == nil
      assert card("keep_score", %{}, %{action: "reset", scores: [], leaders: []}) == nil
    end

    test "from a real add, and it encodes" do
      ctx = %{session_id: "s", user_id: System.unique_integer([:positive]), seed: 1}
      r = run("keep_score", %{"action" => "add", "player" => "Sam", "points" => 2}, ctx)
      c = card("keep_score", %{}, r)
      assert [%{name: "Sam", points: "2", delta: "+2", leader: true}] = c.rows
      assert Jason.encode!(c)
    end
  end

  describe "one scoreboard a turn (App.Cards.fold/3)" do
    # A turn's keep_score results, in arrival order, folded the way the Conversation does.
    defp fold_all(results), do: Enum.reduce(results, nil, &Cards.fold("keep_score", &2, &1))

    defp board(version, scores),
      do: %{scores: for({p, s} <- scores, do: %{player: p, score: s}), version: version}

    defp add(version, player, points, scores),
      do: Map.merge(board(version, scores), %{action: "add", player: player, points: points})

    defp deltas(card), do: Map.new(card.rows, &{&1.name, &1[:delta]})

    test "only the scoreboard has a slot" do
      assert Cards.slot("keep_score") == "scoreboard"
      assert Cards.slot("roll_dice") == nil
      assert Cards.slot("read_list") == nil
    end

    test "parallel adds make one board, the freshest, with every player's change on it" do
      # The 02:17 game: four adds in one round, each result reading the board after its own
      # write, so the earlier results hold only part of the round.
      results = [
        add(1, "Sam", 3, [{"Sam", 3}]),
        add(2, "Ana", 2, [{"Sam", 3}, {"Ana", 2}]),
        add(3, "Joe", 5, [{"Joe", 5}, {"Sam", 3}, {"Ana", 2}]),
        add(4, "Kim", 1, [{"Joe", 5}, {"Sam", 3}, {"Ana", 2}, {"Kim", 1}])
      ]

      c = card("keep_score", %{}, fold_all(results))
      assert c.slot == "scoreboard"
      assert Enum.map(c.rows, & &1.name) == ~w(Joe Sam Ana Kim)
      assert deltas(c) == %{"Joe" => "+5", "Sam" => "+3", "Ana" => "+2", "Kim" => "+1"}
    end

    test "a result that lands late with an older board doesn't put the old board back" do
      results = [
        add(2, "Ana", 2, [{"Sam", 3}, {"Ana", 2}]),
        # read before Ana's write, delivered after it
        add(1, "Sam", 3, [{"Sam", 3}])
      ]

      c = card("keep_score", %{}, fold_all(results))
      assert Enum.map(c.rows, &{&1.name, &1.points}) == [{"Sam", "3"}, {"Ana", "2"}]
      assert deltas(c) == %{"Sam" => "+3", "Ana" => "+2"}
    end

    test "two adds to one player show their sum; a net zero shows nothing" do
      c =
        card(
          "keep_score",
          %{},
          fold_all([
            add(1, "Sam", 3, [{"Sam", 3}, {"Ana", 0}]),
            add(2, "Sam", 2, [{"Sam", 5}, {"Ana", 0}]),
            add(3, "Ana", 4, [{"Sam", 5}, {"Ana", 4}]),
            add(4, "Ana", -4, [{"Sam", 5}, {"Ana", 0}])
          ])
        )

      assert deltas(c) == %{"Sam" => "+5", "Ana" => nil}
    end

    test "a set clears that player's change; a show changes nothing; a reset starts over" do
      set = Map.merge(board(2, [{"Sam", 10}, {"Ana", 2}]), %{action: "set", player: "Sam"})
      show = Map.put(board(3, [{"Sam", 10}, {"Ana", 2}]), :action, "show")

      c =
        card(
          "keep_score",
          %{},
          fold_all([add(1, "Sam", 3, [{"Sam", 3}, {"Ana", 2}]), set, show])
        )

      assert deltas(c) == %{"Sam" => nil, "Ana" => nil}

      sam = add(1, "Sam", 3, [{"Sam", 3}])
      reset = Map.put(board(2, []), :action, "reset")
      assert card("keep_score", %{}, fold_all([sam, reset])) == nil
      ana = add(3, "Ana", 1, [{"Ana", 1}])
      assert deltas(card("keep_score", %{}, fold_all([sam, reset, ana]))) == %{"Ana" => "+1"}
    end

    test "a show on its own (a later turn's print) marks no change from earlier turns" do
      show = Map.put(board(9, [{"Sam", 3}, {"Ana", 2}]), :action, "show")
      assert deltas(card("keep_score", %{}, fold_all([show]))) == %{"Sam" => nil, "Ana" => nil}
    end

    test "from real parallel calls, however their results land" do
      ctx = %{session_id: "s", user_id: System.unique_integer([:positive]), seed: 1}

      results =
        [{"Sam", 3}, {"Ana", 2}, {"Joe", 5}, {"Kim", 1}]
        |> Task.async_stream(fn {p, n} ->
          run("keep_score", %{"action" => "add", "player" => p, "points" => n}, ctx)
        end)
        |> Enum.map(fn {:ok, r} -> r end)

      for order <- [results, Enum.reverse(results)] do
        c = card("keep_score", %{}, fold_all(order))
        assert Enum.map(c.rows, & &1.name) == ~w(Joe Sam Ana Kim)
        assert deltas(c) == %{"Joe" => "+5", "Sam" => "+3", "Ana" => "+2", "Kim" => "+1"}
      end
    end

    test "a malformed result never raises" do
      assert Cards.fold("keep_score", nil, :garbage) == :garbage
      assert Cards.fold("read_list", nil, %{items: []}) == %{items: []}
    end
  end

  test "the brain is told a game result is on screen" do
    r = %{flips: ["heads"], heads: 1, tails: 0}

    assert %{display: _} =
             App.Adapters.TextModel.Gemini.with_card_note(%{result: r}, "flip_coin", %{}, r)
  end
end
