defmodule App.Games.Scores do
  @moduledoc """
  Game night's scoreboards, one per owner (a user id), in memory. A restart wipes them, which
  is fine for a game night — nothing here is worth a table.

  Players match case-insensitively ("SAM" scores for "Sam") and keep the spelling they were
  first given. The board reads leader first; equal scores keep the order the players joined.
  Every write goes through this one process, so parallel tool calls ("two points each to Sam
  and Ana") can't lose an update.
  """
  use Agent

  @max_players 20

  @type board :: [%{name: String.t(), score: integer()}]

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "Adds `points` (may be negative) to `player`, who starts at 0 if new."
  @spec add(term(), String.t(), integer()) ::
          {:ok, %{name: String.t(), score: integer()}} | {:error, String.t()}
  def add(owner, player, points), do: update(owner, player, &(&1 + points))

  @doc "Sets `player`'s score to `points`."
  @spec set(term(), String.t(), integer()) ::
          {:ok, %{name: String.t(), score: integer()}} | {:error, String.t()}
  def set(owner, player, points), do: update(owner, player, fn _ -> points end)

  @doc "The owner's board, leader first. `[]` when there's no game."
  @spec board(term()) :: board()
  def board(owner) do
    __MODULE__
    |> Agent.get(&Map.get(&1, owner, %{}))
    |> Map.values()
    |> Enum.sort_by(&{-&1.score, &1.seq})
    |> Enum.map(&Map.take(&1, [:name, :score]))
  end

  @doc "Clears the owner's board."
  @spec reset(term()) :: :ok
  def reset(owner), do: Agent.update(__MODULE__, &Map.delete(&1, owner))

  defp update(owner, player, fun) do
    name = player |> String.split() |> Enum.join(" ")
    key = String.downcase(name)

    Agent.get_and_update(__MODULE__, fn all ->
      players = Map.get(all, owner, %{})

      case Map.get(players, key) do
        nil when map_size(players) >= @max_players ->
          {{:error, "I can keep score for up to #{@max_players} players."}, all}

        found ->
          row = found || %{name: name, score: 0, seq: map_size(players)}
          row = %{row | score: fun.(row.score)}

          {{:ok, %{name: row.name, score: row.score}},
           Map.put(all, owner, Map.put(players, key, row))}
      end
    end)
  end
end
