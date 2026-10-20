defmodule App.HomeAssistant.Phrases do
  @moduledoc """
  The words the house answers to, for preselecting the home kit (`App.Toolkits.Home.wants?/2`):
  every in-view entity's name with its generic device tail cut ("Dining table lights" →
  "dining table"), every alias, and every area — normalized exactly like the text they're
  matched against. Pure.

  They change only when the directory is (re)built, never on a state event, so
  `App.HomeAssistant.Live` computes them once per build and publishes them
  (`App.HomeAssistant.phrases/0`): preselecting a turn never calls the live client and never
  copies the house.
  """

  alias App.HomeAssistant.Directory

  # Trailing device words cut from a name to get its core ("Fireplace Switch" → "fireplace").
  @tails ~w(light lights lamp lamps switch plug power)
  # Shorter cores ("tv", "ac") would match everyday words; the kit's vocabulary covers types.
  @min_len 4

  @doc "The sorted, unique phrases for `dir`."
  @spec from_directory(Directory.t()) :: [String.t()]
  def from_directory(%Directory{} = dir) do
    names =
      Enum.flat_map(Directory.entries(dir), fn e ->
        [core(e.name) | Enum.map(e.aliases, &normalize/1)]
      end)

    (names ++ Enum.map(dir.areas, &normalize/1))
    |> Enum.filter(&(String.length(&1) >= @min_len))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Lowercase words separated by single spaces: punctuation and runs of space collapse."
  @spec normalize(String.t() | nil) :: String.t()
  def normalize(nil), do: ""

  def normalize(text) when is_binary(text) do
    text |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, " ") |> String.trim()
  end

  defp core(name) do
    name |> normalize() |> String.split(" ", trim: true) |> strip_tails() |> Enum.join(" ")
  end

  defp strip_tails(words) do
    case Enum.reverse(words) do
      [last | rest] when last in @tails and rest != [] -> strip_tails(Enum.reverse(rest))
      _ -> words
    end
  end
end
