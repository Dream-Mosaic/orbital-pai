defmodule App.Conversations.WakeWord do
  @moduledoc """
  Pure wake-trigger matcher for voice activation (the kiosk wake-word gate).
  Spec: docs/superpowers/specs/2026-07-03-voice-activation-v2-design.md

  Two trigger forms:

    * **attention prefix + name** — "wake up Henry", "hey Henry" — matched anywhere
      in the utterance (TV chatter may precede it inside the same Ink turn)
    * **vocative name** — the name as the first word of a sentence (start of the
      transcript, or right after `.` `!` `?`)

  A name occurrence is the configured name (case-insensitive), any `wake_aliases`
  entry (case-insensitive, word-boundary, multi-word allowed), or — when
  `wake_fuzzy` — a token of length >= 4 within Levenshtein distance 1 of the name
  ("Henri", "Hendry"; never "hen"). Mid-sentence mentions without a prefix never
  match ("I think Henry got it wrong").
  """

  # Longest first so multi-word commands win before their own leading word.
  @command_words ["never mind", "nevermind", "hold on", "stop", "wait", "shush", "quiet"]

  @doc """
  Find the first wake trigger in `text`. Returns `{:wake, rest}` — the text after
  the trigger, leading separators trimmed — or `:none`.
  """
  @spec match(String.t(), App.Config.t()) :: :none | {:wake, String.t()}
  def match(text, cfg) when is_binary(text) do
    text
    |> occurrences(cfg)
    |> Enum.filter(fn {start, _stop} -> triggered?(text, start, cfg) end)
    |> Enum.min_by(fn {start, _stop} -> start end, fn -> nil end)
    |> case do
      nil -> :none
      {_start, stop} -> {:wake, rest_after(text, stop)}
    end
  end

  @doc """
  Does `rest` (the text after a wake trigger) begin with a command word?
  `"stop"` → `{:command, ""}`; `"stop, what's the time"` → `{:command, "what's the time"}`;
  anything else → `:none`.
  """
  @spec command_rest(String.t()) :: :none | {:command, String.t()}
  def command_rest(rest) when is_binary(rest) do
    trimmed = String.trim_leading(rest)
    down = String.downcase(trimmed)

    Enum.find_value(@command_words, :none, fn cw ->
      len = String.length(cw)

      cond do
        String.replace(down, ~r/[\s,.!?;:]+\z/u, "") == cw ->
          {:command, ""}

        String.starts_with?(down, cw) and not word_char?(String.at(down, len)) ->
          {:command, trimmed |> String.slice(len..-1//1) |> trim_lead()}

        true ->
          nil
      end
    end)
  end

  @doc """
  Does `rest` (the text after a wake trigger) begin with a SLEEP word from
  `cfg.sleep_words`? Sleep has no tail, so this is a boolean.
  `"sleep"` / `"lock"` / `"go to sleep"` → true; `"sleeping"` / `"locket"` → false
  (word boundary). Trailing punctuation on a bare sleep word is tolerated.
  """
  @spec sleep_command?(String.t(), App.Config.t()) :: boolean()
  def sleep_command?(rest, cfg) when is_binary(rest) do
    down = rest |> String.trim_leading() |> String.downcase()
    bare = String.replace(down, ~r/[\s,.!?;:]+\z/u, "")

    Enum.any?(cfg.sleep_words, fn sw ->
      sw = String.downcase(sw)
      len = String.length(sw)

      bare == sw or
        (String.starts_with?(down, sw) and not word_char?(String.at(down, len))) or
        fuzzy_sleep?(bare, sw)
    end)
  end

  # Ink-2 truncates/mishears the one-word command "sleep" as "slee"/"seep" — the exact/boundary
  # match above then misses the very word it guards, and the utterance leaks to the brain. When
  # the WHOLE utterance is a single (misheard) word, tolerate it within Levenshtein 1 of a
  # single-word sleep word of length >= 5. The length gate keeps short words (e.g. "lock", 4)
  # EXACT-only so "look" (the vision cue), "lick", "lack" can never lock him; the single-token
  # gate keeps "sweep the floor" and the like from matching.
  defp fuzzy_sleep?(bare, sw) do
    String.length(sw) >= 5 and not String.contains?(sw, " ") and
      single_token?(bare) and String.length(bare) >= 4 and levenshtein(bare, sw) <= 1
  end

  defp single_token?(s), do: s != "" and not String.match?(s, ~r/\s/u)

  # ---- name occurrences: byte ranges {start, stop} ----

  defp occurrences(text, cfg) do
    exact =
      [cfg.name | cfg.wake_aliases]
      |> Enum.reject(&(is_nil(&1) or String.trim(&1) == ""))
      |> Enum.flat_map(fn variant ->
        pattern =
          variant
          |> String.trim()
          |> Regex.escape()
          # multi-word aliases tolerate any whitespace run between words
          |> String.replace("\\ ", "\\s+")

        ~r/(?<![\p{L}\p{N}])#{pattern}(?![\p{L}\p{N}])/iu
        |> Regex.scan(text, return: :index)
        |> Enum.map(fn [{start, len} | _] -> {start, start + len} end)
      end)

    (exact ++ fuzzy_occurrences(text, cfg)) |> Enum.uniq() |> Enum.sort()
  end

  defp fuzzy_occurrences(_text, %{wake_fuzzy: false}), do: []

  defp fuzzy_occurrences(text, cfg) do
    name = String.downcase(cfg.name)

    ~r/[\p{L}\p{N}']+/u
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{start, len} | _] -> {start, len} end)
    |> Enum.filter(fn {start, len} ->
      word = text |> binary_part(start, len) |> String.downcase()
      String.length(word) >= 4 and levenshtein(word, name) <= 1
    end)
    |> Enum.map(fn {start, len} -> {start, start + len} end)
  end

  # ---- trigger position: vocative OR attention-prefixed ----

  defp triggered?(text, start, cfg) do
    preceding = binary_part(text, 0, start)
    vocative?(preceding) or prefixed?(preceding, cfg.wake_prefixes)
  end

  defp vocative?(preceding) do
    case String.trim_trailing(preceding) do
      "" -> true
      p -> String.ends_with?(p, [".", "!", "?"])
    end
  end

  defp prefixed?(preceding, prefixes) do
    # drop whitespace/commas between prefix and name ("hey, Henry")
    p = preceding |> String.downcase() |> String.replace(~r/[\s,]+\z/u, "")

    Enum.any?(prefixes, fn pre ->
      String.ends_with?(p, pre) and boundary_before?(p, pre)
    end)
  end

  # the char before the prefix must be a non-word char (or the string start)
  defp boundary_before?(p, pre) do
    String.length(p) == String.length(pre) or
      not word_char?(String.at(p, String.length(p) - String.length(pre) - 1))
  end

  defp word_char?(nil), do: false
  defp word_char?(ch), do: String.match?(ch, ~r/[\p{L}\p{N}]/u)

  defp rest_after(text, stop),
    do: text |> binary_part(stop, byte_size(text) - stop) |> trim_lead()

  defp trim_lead(s), do: String.replace(s, ~r/\A[\s,.!?;:–—-]+/u, "")

  @doc false
  # Two-row Levenshtein; inputs are name-sized, perf is irrelevant.
  def levenshtein(a, b) do
    gb = String.graphemes(b)

    a
    |> String.graphemes()
    |> Enum.with_index(1)
    |> Enum.reduce(Enum.to_list(0..length(gb)), fn {ca, i}, prev ->
      {row, _} =
        gb
        |> Enum.with_index(1)
        |> Enum.reduce({[i], prev}, fn {cb, j}, {row, prev} ->
          cost = if ca == cb, do: 0, else: 1

          val =
            Enum.min([
              Enum.at(prev, j) + 1,
              hd(row) + 1,
              Enum.at(prev, j - 1) + cost
            ])

          {[val | row], prev}
        end)

      Enum.reverse(row)
    end)
    |> List.last()
  end
end
