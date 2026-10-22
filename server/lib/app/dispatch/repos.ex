defmodule App.Dispatch.Repos do
  @moduledoc """
  Pure resolution of a spoken repo name ("the chronicles app", "Henry") to one of the forge's
  repos. Normalizes (downcase, `-`/`_` as spaces, drops "app"/"repo"/"project"/"the"), checks
  aliases first, then exact name, then word-subset matching that tolerates a typo on words of
  four or more letters (two on eight or more).
  """

  @drop ~w(app repo project the)

  @type repo :: %{required(:name) => String.t(), optional(atom()) => term()}

  @spec resolve([repo()], String.t(), %{optional(String.t()) => String.t()}) ::
          {:ok, repo()} | {:ambiguous, [repo()]} | {:none, [repo()]}
  def resolve(repos, phrase, aliases \\ %App.Config{}.repo_aliases) do
    case words(phrase) do
      [] -> {:none, repos}
      ws -> by_alias(repos, phrase, ws, aliases)
    end
  end

  defp by_alias(repos, phrase, ws, aliases) do
    key = phrase |> String.downcase() |> String.trim()
    aliased = Map.get(aliases, key) || Map.get(aliases, Enum.join(ws, " "))

    case aliased && Enum.find(repos, &(&1.name == aliased)) do
      %{} = repo -> {:ok, repo}
      _ -> by_name(repos, ws)
    end
  end

  defp by_name(repos, ws) do
    exact = Enum.filter(repos, &(words(&1.name) == ws))
    subset = fn -> Enum.filter(repos, &subset?(ws, words(&1.name))) end

    case if(exact == [], do: subset.(), else: exact) do
      [one] -> {:ok, one}
      [] -> {:none, repos}
      many -> {:ambiguous, many}
    end
  end

  defp subset?(phrase_words, name_words),
    do: Enum.all?(phrase_words, fn w -> Enum.any?(name_words, &close?(w, &1)) end)

  defp close?(a, a), do: true

  # One slip on 4-7 letter words, two on longer ones ("chronicals" is a vowel swap plus a
  # slipped letter away from "chronicles").
  defp close?(a, b) do
    len = min(String.length(a), String.length(b))
    len >= 4 and edit_distance(a, b) <= if(len >= 8, do: 2, else: 1)
  end

  @doc false
  def words(text) do
    text
    |> String.downcase()
    |> String.replace(["-", "_"], " ")
    |> String.split(~r/[^[:alnum:]]+/u, trim: true)
    |> Enum.reject(&(&1 in @drop))
  end

  # Levenshtein, early-exit friendly sizes (names are short).
  defp edit_distance(a, b) do
    a = String.graphemes(a)
    b = String.graphemes(b)
    row = Enum.to_list(0..length(b))

    a
    |> Enum.with_index(1)
    |> Enum.reduce(row, fn {ca, i}, prev ->
      b
      |> Enum.zip(Enum.zip(prev, tl(prev)))
      |> Enum.reduce([i], fn {cb, {diag, up}}, [left | _] = acc ->
        [min(min(left + 1, up + 1), diag + if(ca == cb, do: 0, else: 1)) | acc]
      end)
      |> Enum.reverse()
    end)
    |> List.last()
  end
end
