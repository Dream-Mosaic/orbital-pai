defmodule App.Cards.Games do
  @moduledoc """
  Game night's cards (`App.Tools.Games` results), built for a wall read from across the table:
  `dice` (each die, the arithmetic, the total), `coin` (each flip as a disc), `pick` (the chosen
  among the options, or a numbered turn order) and `scoreboard` (rank, name, points, leader
  lit). `App.Cards.from_tool/4` routes here; like every card, the strings are made here and the
  client only lays them out.
  """

  @scoreboard_cap 10
  # The typographic minus: "−2" reads as a negative from across the room; "-2" reads as a dash.
  @minus "−"

  @doc false
  def dice(%{dice: [_ | _] = dice, modifier: mod, notation: notation} = r) do
    single? = match?([_], dice) and mod == 0

    compact(%{
      type: "dice",
      title: "Rolled #{notation}",
      dice: dice,
      pips: if(r[:sides] == 6, do: true),
      modifier: if(mod != 0, do: signed(mod)),
      total: if(not single?, do: Integer.to_string(r.total)),
      math: if(not single?, do: math(dice, mod))
    })
  end

  def dice(_), do: nil

  # "5 + 1 + 7 + 2", "4 − 1"
  defp math(dice, mod) do
    sum = Enum.map_join(dice, " + ", &Integer.to_string/1)

    cond do
      mod > 0 -> "#{sum} + #{mod}"
      mod < 0 -> "#{sum} #{@minus} #{-mod}"
      true -> sum
    end
  end

  @doc false
  def coin(%{flips: [_ | _] = flips} = r) do
    n = length(flips)

    compact(%{
      type: "coin",
      title: if(n == 1, do: "Coin flip", else: "#{n} coin flips"),
      flips: Enum.map(flips, &face/1),
      summary: if(n > 1, do: tally(r[:heads] || 0, r[:tails] || 0))
    })
  end

  def coin(_), do: nil

  defp face("heads"), do: %{side: "heads", label: "Heads", mark: "H"}
  defp face("tails"), do: %{side: "tails", label: "Tails", mark: "T"}

  defp tally(h, t) do
    [{h, "head"}, {t, "tail"}]
    |> Enum.reject(fn {n, _} -> n == 0 end)
    |> Enum.map_join(" · ", fn {n, word} -> "#{n} #{word}#{if n == 1, do: "", else: "s"}" end)
  end

  @doc false
  def pick(%{order: [_ | _] = order}) do
    %{
      type: "pick",
      title: "Turn order",
      order:
        order
        |> Enum.with_index(1)
        |> Enum.map(fn {label, i} -> %{rank: Integer.to_string(i), label: label} end)
    }
  end

  def pick(%{options: [_ | _] = options, picked: [_ | _] = picked}) do
    chosen = MapSet.new(picked)
    n = length(picked)

    %{
      type: "pick",
      title: if(n == 1, do: "Picked", else: "Picked #{n}"),
      headline: and_join(picked),
      options: Enum.map(options, &%{label: &1, chosen: MapSet.member?(chosen, &1)}),
      trailing: "#{n} of #{length(options)}"
    }
  end

  def pick(_), do: nil

  defp and_join([one]), do: one
  defp and_join(many), do: Enum.join(Enum.drop(many, -1), ", ") <> " and " <> List.last(many)

  @doc false
  def scoreboard(%{scores: [_ | _] = scores} = r) do
    top = scores |> Enum.map(& &1.score) |> Enum.max()
    # Everyone level (and more than one of them) is nobody's lead.
    lead? = length(scores) == 1 or Enum.any?(scores, &(&1.score != top))
    ranks = ranks(scores)

    rows =
      scores
      |> Enum.zip(ranks)
      |> Enum.take(@scoreboard_cap)
      |> Enum.map(fn {s, rank} ->
        compact(%{
          rank: Integer.to_string(rank),
          name: s.player,
          points: signed_plain(s.score),
          leader: lead? and s.score == top,
          delta: delta(r, s.player)
        })
      end)

    n = length(scores)

    compact(%{
      type: "scoreboard",
      title: "Scoreboard",
      trailing: if(n == 1, do: "1 player", else: "#{n} players"),
      rows: rows,
      more: if(n > @scoreboard_cap, do: "+#{n - @scoreboard_cap} more")
    })
  end

  def scoreboard(_), do: nil

  # Competition ranking: 8, 5, 5, -2 → 1, 2, 2, 4.
  defp ranks(scores) do
    {ranks, _} =
      scores
      |> Enum.with_index(1)
      |> Enum.map_reduce(nil, fn
        {%{score: s}, _i}, {s, rank} -> {rank, {s, rank}}
        {%{score: s}, i}, _ -> {i, {s, i}}
      end)

    ranks
  end

  # The points just added, beside the player they went to ("+3"); a set or a show has none.
  defp delta(%{action: "add", player: player, points: points}, player), do: signed(points)
  defp delta(_r, _player), do: nil

  defp signed(n) when n >= 0, do: "+" <> group(n)
  defp signed(n), do: @minus <> group(-n)

  defp signed_plain(n) when n >= 0, do: group(n)
  defp signed_plain(n), do: @minus <> group(-n)

  # "1,200"
  defp group(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp compact(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
