defmodule App.Games do
  @moduledoc """
  Game night's chance, kept honest: dice notation, rolls, coin flips and shuffles. Pure — every
  draw threads an explicit `:rand` state, so a test hands in a seed and gets the same answers
  every time, while a real call (`rng(nil)`) is seeded from `:crypto` and is fair.

  The tool (`App.Tools.Games`) owns the arguments and results; the scores live in
  `App.Games.Scores`.
  """

  @max_dice 10
  @sides 2..100
  @max_modifier 100

  @notation_error "I can only roll dice written like 2d6, d20 or 3d8+2."

  @typedoc "A parsed roll: how many dice, how many sides each, and what to add."
  @type spec :: %{count: pos_integer(), sides: pos_integer(), modifier: integer()}

  @doc """
  Reads dice notation ("2d6", "d20", "3d8+2", "1d6-1"; case and spaces don't matter).
  An error is a sentence the brain can say.
  """
  @spec parse_dice(term()) :: {:ok, spec()} | {:error, String.t()}
  def parse_dice(notation) when is_binary(notation) do
    compact = notation |> String.replace(~r/\s+/u, "") |> String.downcase()

    case Regex.run(~r/^(\d*)d(\d+)(?:([+-])(\d+))?$/, compact) do
      [_ | groups] -> groups |> pad(4) |> spec()
      nil -> {:error, @notation_error}
    end
  end

  def parse_dice(_), do: {:error, @notation_error}

  defp pad(list, n), do: list ++ List.duplicate("", n - length(list))

  defp spec([count, sides, sign, mod]) do
    count = if count == "", do: 1, else: String.to_integer(count)
    sides = String.to_integer(sides)
    mod = if mod == "", do: 0, else: String.to_integer(mod)
    modifier = if sign == "-", do: -mod, else: mod

    cond do
      count < 1 or count > @max_dice ->
        {:error, "I can roll 1 to #{@max_dice} dice at a time."}

      sides not in @sides ->
        {:error, "Dice need #{@sides.first} to #{@sides.last} sides."}

      abs(modifier) > @max_modifier ->
        {:error, "The modifier has to be between -#{@max_modifier} and +#{@max_modifier}."}

      true ->
        {:ok, %{count: count, sides: sides, modifier: modifier}}
    end
  end

  @doc """
  A `:rand` state. `nil` seeds it from `:crypto` (a real roll); an integer or a three-integer
  tuple seeds it deterministically (tests).
  """
  @spec rng(nil | integer() | {integer(), integer(), integer()}) :: :rand.state()
  def rng(nil) do
    <<a::32, b::32, c::32>> = :crypto.strong_rand_bytes(12)
    :rand.seed_s(:exsss, {a, b, c})
  end

  def rng(seed) when is_integer(seed), do: :rand.seed_s(:exsss, {seed, seed + 1, seed + 2})
  def rng({_, _, _} = seed), do: :rand.seed_s(:exsss, seed)

  @doc "Rolls a parsed spec: each die's face, in the order rolled."
  @spec roll(spec(), :rand.state()) :: {[pos_integer()], :rand.state()}
  def roll(%{count: count, sides: sides}, state),
    do: draws(count, state, &:rand.uniform_s(sides, &1))

  @doc "`count` coin flips, each \"heads\" or \"tails\"."
  @spec flip(pos_integer(), :rand.state()) :: {[String.t()], :rand.state()}
  def flip(count, state) do
    draws(count, state, fn st ->
      {n, st} = :rand.uniform_s(2, st)
      {if(n == 1, do: "heads", else: "tails"), st}
    end)
  end

  @doc "A uniformly random permutation of `list` (Fisher–Yates)."
  @spec shuffle(list(), :rand.state()) :: {list(), :rand.state()}
  def shuffle(list, state) do
    {arr, state} =
      list
      |> Enum.with_index()
      |> Map.new(fn {x, i} -> {i, x} end)
      |> fisher_yates(length(list) - 1, state)

    {Enum.map(0..(length(list) - 1)//1, &Map.fetch!(arr, &1)), state}
  end

  defp fisher_yates(arr, i, state) when i <= 0, do: {arr, state}

  defp fisher_yates(arr, i, state) do
    {j, state} = :rand.uniform_s(i + 1, state)
    j = j - 1
    arr = %{arr | i => arr[j], j => arr[i]}
    fisher_yates(arr, i - 1, state)
  end

  defp draws(count, state, draw) do
    {acc, state} =
      Enum.reduce(1..count//1, {[], state}, fn _, {acc, st} ->
        {x, st} = draw.(st)
        {[x | acc], st}
      end)

    {Enum.reverse(acc), state}
  end
end
