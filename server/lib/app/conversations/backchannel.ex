defmodule App.Conversations.Backchannel do
  @moduledoc """
  Classifies speech that arrives while Henry is talking (the interrupt-confirmation window).
  Spec: docs/superpowers/specs/2026-07-03-full-duplex-feel-design.md

    * `:noise` — no letters (a wordless interim): keep waiting, stay ducked.
    * `:backchannel` — a short acknowledgment ("uh huh", "no way!"): un-duck, keep talking.
    * `:interrupt` — real speech: yield.
  """

  @lexicon ~w(uh huh mm hmm mhm yeah yep yes right ok okay wow whoa no way sure exactly
              totally true nice cool damn really interesting ha haha oh)

  @max_backchannel_tokens 3

  @spec classify(String.t() | nil) :: :noise | :backchannel | :interrupt
  def classify(text) when is_binary(text) do
    tokens =
      text
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}']+/u, trim: true)

    cond do
      not String.match?(text, ~r/\p{L}/u) ->
        :noise

      length(tokens) <= @max_backchannel_tokens and Enum.all?(tokens, &(&1 in @lexicon)) ->
        :backchannel

      true ->
        :interrupt
    end
  end

  def classify(_), do: :noise
end
