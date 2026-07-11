defmodule App.Conversations.LookIntent do
  @moduledoc """
  Pure trigger for the vision feature: does the finished turn transcript ask the assistant to
  LOOK at something right now? A conservative, case-insensitive substring phrase list —
  deterministic, cheap, and easy to tune. A false positive costs only ~1s + one unused frame
  (the brain still answers), so the list leans toward the clearly-visual asks.

  Spec: docs/superpowers/specs/2026-07-10-vision-look-at-this-design.md
  """

  # Substring match, lowercased. Note "look at the" does NOT fire on "looking at the" (the "ing"
  # breaks the run). Tune here — it's the whole trigger surface. A false positive costs only ~1s +
  # one unused frame, so the list leans permissive toward clearly-visual asks; the phrasings below
  # the divider were added after a live smoke where "take a picture of this" fell through to a
  # no-camera turn (the brain then said "I can't access your camera").
  @phrases [
    "look at this",
    "look at that",
    "look at the",
    "look at my",
    "look at something",
    "look here",
    "can you see this",
    "can you see that",
    "do you see this",
    "do you see that",
    "what is this",
    "what is that",
    "what's this",
    "what's that",
    "check this out",
    "read this",
    "see this",
    # camera-framed / "what am I holding" phrasings (live-smoke gap)
    "take a picture",
    "take a photo",
    "take a pic",
    "snap a photo",
    "snap a picture",
    "what do you see",
    "what can you see",
    "what am i holding",
    "what am i looking at"
  ]

  @spec wants_look?(term(), App.Config.t()) :: boolean()
  def wants_look?(text, _cfg) when is_binary(text) do
    down = String.downcase(text)
    Enum.any?(@phrases, &String.contains?(down, &1))
  end

  def wants_look?(_text, _cfg), do: false
end
