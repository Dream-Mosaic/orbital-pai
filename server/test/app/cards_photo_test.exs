defmodule App.CardsPhotoTest do
  use ExUnit.Case, async: true

  alias App.Adapters.TextModel.Gemini
  alias App.Cards

  # "Henry, look at this" (spec 2026-10-23-game-night-design, section 1): the photo card
  # names the capture; the app shows the snapshot it kept for that id (or a quiet "photo not
  # kept" placeholder on replay or another device). The image itself never rides the card.

  @seen %{seen: "A red coffee mug.", capture_id: "0b8e4a5e-8f3c-4f0e-9d7c-6a1b2c3d4e5f"}

  test "a look result is a photo card: the capture id and the question as caption" do
    assert Cards.from_tool("look", %{"question" => " what am I holding? "}, @seen) == %{
             type: "photo",
             capture_id: @seen.capture_id,
             caption: "what am I holding?"
           }
  end

  test "a missing question still captions the card" do
    assert %{type: "photo", caption: "What is this?"} = Cards.from_tool("look", %{}, @seen)
    assert %{type: "photo", caption: "What is this?"} = Cards.from_tool("look", nil, @seen)
  end

  test "an error- or note-shaped result is no card" do
    assert Cards.from_tool("look", %{"question" => "q"}, %{error: "nope"}) == nil
    assert Cards.from_tool("look", %{"question" => "q"}, "I can't see from this device.") == nil
    assert Cards.from_tool("look", %{"question" => "q"}, %{seen: "x"}) == nil
  end

  test "the card is small enough to replay with the turn" do
    card = Cards.from_tool("look", %{"question" => "what's this?"}, @seen)
    assert Cards.for_history([card]) == [card]
  end

  test "the brain is NOT told the card shows the answer — the card shows only the photo" do
    response = %{result: @seen}
    assert Gemini.with_card_note(response, "look", %{"question" => "q"}, @seen) == response
  end
end
