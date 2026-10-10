defmodule App.CardsHistoryTest do
  # The cards a persisted turn keeps for history replay (App.Cards.for_history/1). Pure.
  use ExUnit.Case, async: true

  alias App.Cards

  defp card(n, extra \\ %{}),
    do:
      Map.merge(%{type: "list", title: "List #{n}", items: [%{text: "milk", done: false}]}, extra)

  test "a turn that showed no cards stores nothing" do
    assert Cards.for_history(nil) == nil
    assert Cards.for_history([]) == nil
  end

  test "keeps the cards in the order the user saw them" do
    assert Cards.for_history([card(1), card(2)]) == [card(1), card(2)]
  end

  test "at most four cards per turn; the extras are dropped" do
    cards = Enum.map(1..6, &card/1)
    assert Cards.for_history(cards) == Enum.map(1..4, &card/1)
  end

  test "a card that would push the turn past ~16 KB of JSON is dropped; smaller ones still fit" do
    huge = card(2, %{title: String.duplicate("x", 17_000)})
    assert Cards.for_history([card(1), huge, card(3)]) == [card(1), card(3)]
  end

  test "the budget is shared by the turn's cards, not granted to each" do
    big = fn n -> card(n, %{title: String.duplicate("y", 6_000)}) end
    kept = Cards.for_history([big.(1), big.(2), big.(3)])
    assert kept == [big.(1), big.(2)]
    assert kept |> Jason.encode!() |> byte_size() <= 16 * 1024
  end

  test "nothing surviving the cap is stored as nothing, not an empty list" do
    assert Cards.for_history([card(1, %{title: String.duplicate("z", 20_000)})]) == nil
  end
end
