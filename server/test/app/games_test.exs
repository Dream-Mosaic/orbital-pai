defmodule App.GamesTest do
  use ExUnit.Case, async: true

  alias App.Games

  describe "parse_dice/1" do
    test "reads count, sides and modifier from common notation" do
      for {notation, parsed} <- [
            {"2d6", %{count: 2, sides: 6, modifier: 0}},
            {"d20", %{count: 1, sides: 20, modifier: 0}},
            {"3d8+2", %{count: 3, sides: 8, modifier: 2}},
            {"1d6-1", %{count: 1, sides: 6, modifier: -1}},
            {"2D6", %{count: 2, sides: 6, modifier: 0}},
            {" 4 d 10 + 3 ", %{count: 4, sides: 10, modifier: 3}},
            {"10d100", %{count: 10, sides: 100, modifier: 0}},
            {"d2", %{count: 1, sides: 2, modifier: 0}}
          ] do
        assert Games.parse_dice(notation) == {:ok, parsed}, notation
      end
    end

    test "unreadable notation is a sentence the brain can say" do
      for bad <- ["", "two dice", "2d", "d", "2x6", "2d6+", "2d6+1+1", "-2d6", "2.5d6", nil, 6] do
        assert {:error, msg} = Games.parse_dice(bad), inspect(bad)
        assert msg =~ "2d6"
      end
    end

    test "limits: 1 to 10 dice, 2 to 100 sides, a modifier within 100" do
      assert {:error, msg} = Games.parse_dice("11d6")
      assert msg =~ "10 dice"
      assert {:error, _} = Games.parse_dice("0d6")
      assert {:error, msg} = Games.parse_dice("2d1")
      assert msg =~ "2 to 100 sides"
      assert {:error, _} = Games.parse_dice("2d101")
      assert {:error, msg} = Games.parse_dice("2d6+101")
      assert msg =~ "100"
      assert {:ok, %{modifier: -100}} = Games.parse_dice("2d6-100")
    end
  end

  describe "randomness" do
    test "a seed makes every draw repeatable" do
      spec = %{count: 5, sides: 20, modifier: 0}
      {a, _} = Games.roll(spec, Games.rng(42))
      {b, _} = Games.roll(spec, Games.rng(42))
      assert a == b
      {c, _} = Games.roll(spec, Games.rng(43))
      assert a != c
    end

    test "dice land on every face and never off the die" do
      {dice, _} = Games.roll(%{count: 10, sides: 6, modifier: 0}, Games.rng(7))
      assert length(dice) == 10

      faces =
        Enum.reduce(1..100, {MapSet.new(), Games.rng(7)}, fn _, {seen, st} ->
          {ds, st} = Games.roll(%{count: 10, sides: 6, modifier: 0}, st)
          {Enum.into(ds, seen), st}
        end)
        |> elem(0)

      assert faces == MapSet.new(1..6)
    end

    test "an unseeded rng is drawn from :crypto, so two of them differ" do
      spec = %{count: 10, sides: 100, modifier: 0}
      {a, _} = Games.roll(spec, Games.rng(nil))
      {b, _} = Games.roll(spec, Games.rng(nil))
      assert a != b
    end

    test "flip/2 is heads or tails, both turning up" do
      {flips, _} = Games.flip(10, Games.rng(3))
      assert length(flips) == 10
      assert Enum.all?(flips, &(&1 in ["heads", "tails"]))

      {many, _} = Games.flip(10, Games.rng(5))
      assert "heads" in (flips ++ many) and "tails" in (flips ++ many)
    end

    test "shuffle/2 is a permutation, repeatable with a seed" do
      list = ~w(Sam Ana Joe Kim Lee)
      {a, _} = Games.shuffle(list, Games.rng(11))
      {b, _} = Games.shuffle(list, Games.rng(11))
      assert a == b
      assert Enum.sort(a) == Enum.sort(list)
    end
  end
end
