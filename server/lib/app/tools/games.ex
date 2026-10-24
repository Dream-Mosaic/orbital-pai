defmodule App.Tools.Games do
  @moduledoc """
  Game night: `roll_dice`, `flip_coin`, `pick_one` (one or more from a list, or a shuffled
  turn order) and `keep_score` (per-player points). Always on rather than a toolkit, so "roll
  two dice" never costs a `use_toolkit` hop.

  The chance lives in `App.Games` and the scoreboards in `App.Games.Scores`; this module only
  checks the brain's arguments and shapes results it can read out (each also renders as a card,
  `App.Cards`). Nothing here is cached — a cached roll would be a loaded die. `ctx[:seed]`
  pins the randomness for tests; a real call draws a fresh `:crypto` seed.
  """
  @behaviour App.Tools.Tool

  require Logger

  alias App.Games
  alias App.Games.Scores

  @max_flips 10
  @max_options 20
  @max_points 1_000_000

  @impl true
  def declarations do
    [
      %{
        name: "roll_dice",
        description:
          "Roll dice and get each die, the modifier and the total. Shown as a card of dice.",
        parameters: %{
          type: "object",
          properties: %{
            notation: %{
              type: "string",
              description:
                "Dice notation: \"2d6\" (two six-sided dice — what \"roll two dice\" means), " <>
                  "\"d20\", \"3d8+2\", \"1d6-1\". 1 to 10 dice, 2 to 100 sides."
            }
          },
          required: ["notation"]
        }
      },
      %{
        name: "flip_coin",
        description: "Flip a coin (or several): heads or tails for each.",
        parameters: %{
          type: "object",
          properties: %{
            count: %{type: "integer", description: "How many coins, 1 to 10. Default 1."}
          }
        }
      },
      %{
        name: "pick_one",
        description:
          "Pick at random from options the user names: one (\"who goes first: Sam, Ana or " <>
            "Joe?\"), several different ones (count), or all of them shuffled into a turn " <>
            "order (shuffle).",
        parameters: %{
          type: "object",
          properties: %{
            options: %{
              type: "array",
              items: %{type: "string"},
              description: "The options, as said (\"Sam\", \"Ana\", \"Joe\"). 2 to 20."
            },
            count: %{
              type: "integer",
              description: "How many to pick, all different. Default 1."
            },
            shuffle: %{
              type: "boolean",
              description: "true to put every option in a random order (turn order)."
            }
          },
          required: ["options"]
        }
      },
      %{
        name: "keep_score",
        description:
          "The game's scoreboard: add points to a player (negative to take away), set a " <>
            "player's score, show the board, or reset it for a new game. Players are matched " <>
            "by name, ignoring case; a new name joins at 0.",
        parameters: %{
          type: "object",
          properties: %{
            action: %{type: "string", enum: ["add", "set", "show", "reset"]},
            player: %{type: "string", description: "The player's name (for add and set)."},
            points: %{
              type: "integer",
              description: "For add: how many (negative takes away). For set: the new score."
            }
          },
          required: ["action"]
        }
      }
    ]
  end

  @impl true
  def prompt do
    "Game night: roll_dice, flip_coin, pick_one (who goes first, or shuffle for a turn " <>
      "order) and keep_score. Never invent a roll, flip, pick or score — call the tool and " <>
      "read its result."
  end

  @impl true
  def bridge(_name), do: []

  @impl true
  def execute("roll_dice", args, ctx) do
    with {:ok, spec} <- Games.parse_dice(args["notation"]) do
      {dice, _} = Games.roll(spec, rng(ctx))
      total = Enum.sum(dice) + spec.modifier
      Logger.info("[games] rolled #{notation(spec)} → #{total}")

      {:ok,
       %{
         notation: notation(spec),
         sides: spec.sides,
         dice: dice,
         modifier: spec.modifier,
         total: total
       }}
    end
  end

  def execute("flip_coin", args, ctx) do
    with {:ok, count} <- count_arg(Map.get(args, "count", 1), @max_flips, flips_error()) do
      {flips, _} = Games.flip(count, rng(ctx))
      heads = Enum.count(flips, &(&1 == "heads"))
      Logger.info("[games] flipped #{count}: #{heads} heads")
      {:ok, %{flips: flips, heads: heads, tails: count - heads}}
    end
  end

  def execute("pick_one", args, ctx) do
    with {:ok, options} <- options_arg(args["options"]),
         n = length(options),
         {:ok, count} <-
           count_arg(
             Map.get(args, "count", 1),
             n,
             "count must be 1 to #{n} (how many options there are)."
           ) do
      {order, _} = Games.shuffle(options, rng(ctx))
      Logger.info("[games] picked from #{n} options")

      if args["shuffle"] == true or count == n,
        do: {:ok, %{options: options, order: order}},
        else: {:ok, %{options: options, picked: Enum.take(order, count)}}
    end
  end

  def execute("keep_score", args, ctx) do
    owner = owner(ctx)

    case args["action"] do
      action when action in ["add", "set"] ->
        with {:ok, player} <- player_arg(args["player"]),
             {:ok, points} <- points_arg(args["points"]),
             {:ok, %{name: name, score: score}} <- write_score(action, owner, player, points) do
          Logger.info("[games] score #{action} for #{App.LogText.said(name)}")

          {:ok,
           %{action: action, player: name, points: points, score: score}
           |> Map.merge(board(owner))}
        end

      "show" ->
        result = Map.put(board(owner), :action, "show")

        {:ok,
         if(result.scores == [],
           do: Map.put(result, :note, "no scores yet — the board is empty"),
           else: result
         )}

      "reset" ->
        :ok = Scores.reset(owner)
        Logger.info("[games] scoreboard reset")
        {:ok, Map.merge(%{action: "reset", note: "scoreboard cleared"}, board(owner))}

      _ ->
        {:error, "keep_score's action must be add, set, show or reset."}
    end
  end

  def execute(_name, _args, _ctx), do: {:error, :unknown_function}

  defp write_score("add", owner, player, points), do: Scores.add(owner, player, points)
  defp write_score("set", owner, player, points), do: Scores.set(owner, player, points)

  # ---- arguments ----

  defp rng(ctx), do: Games.rng(Map.get(ctx, :seed))

  # The scoreboard belongs to the signed-in user; without one (no session user), the session.
  defp owner(%{user_id: uid}) when not is_nil(uid), do: uid
  defp owner(ctx), do: {:session, Map.get(ctx, :session_id)}

  defp flips_error, do: "I can flip 1 to #{@max_flips} coins at a time."

  defp count_arg(n, max, _error) when is_integer(n) and n >= 1 and n <= max, do: {:ok, n}

  defp count_arg(n, max, error) when is_float(n) and n == trunc(n),
    do: count_arg(trunc(n), max, error)

  defp count_arg(_n, _max, error), do: {:error, error}

  defp options_arg(list) when is_list(list) do
    options =
      list
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&(&1 |> String.split() |> Enum.join(" ")))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq_by(&String.downcase/1)

    cond do
      length(options) < 2 -> {:error, "Give me at least two options to pick from."}
      length(options) > @max_options -> {:error, "I can pick from up to #{@max_options} options."}
      true -> {:ok, options}
    end
  end

  defp options_arg(_), do: {:error, "options must be a list of names or things to pick from."}

  defp player_arg(name) when is_binary(name) do
    if String.trim(name) == "",
      do: player_arg(nil),
      else: {:ok, name}
  end

  defp player_arg(_), do: {:error, "keep_score needs the player's name to add or set points."}

  defp points_arg(n) when is_integer(n) and abs(n) <= @max_points, do: {:ok, n}
  defp points_arg(n) when is_float(n) and n == trunc(n), do: points_arg(trunc(n))

  defp points_arg(_),
    do: {:error, "points must be a whole number, like 3 (or -2 to take points away)."}

  # ---- results ----

  # `version` orders boards read by parallel calls, so their one card shows the freshest.
  defp board(owner) do
    {scores, version} = Scores.snapshot(owner)
    top = scores |> Enum.map(& &1.score) |> Enum.max(fn -> nil end)

    %{
      scores: Enum.map(scores, &%{player: &1.name, score: &1.score}),
      leaders: for(%{name: n, score: ^top} <- scores, do: n),
      version: version
    }
  end

  @doc false
  # "3d8+2", "d20", "2d6-1": how the roll reads back, on the card and to the brain.
  def notation(%{count: count, sides: sides, modifier: mod}) do
    dice = if count == 1, do: "d#{sides}", else: "#{count}d#{sides}"

    cond do
      mod > 0 -> "#{dice}+#{mod}"
      mod < 0 -> "#{dice}#{mod}"
      true -> dice
    end
  end
end
