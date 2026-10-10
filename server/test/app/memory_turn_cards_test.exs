defmodule App.MemoryTurnCardsTest do
  # A turn's visual cards ride along in the turns table for history replay ONLY. Everything that
  # feeds a model or an index reads user_text/brain_text, never the card JSON.
  use App.DataCase, async: false

  alias App.Memory
  alias App.Adapters.TextModel.Gemini

  @card %{
    type: "weather",
    location: "Lakeview",
    temp: "72°",
    condition: "Sunny",
    details: [%{label: "Wind", value: "8 mph S"}]
  }

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "cards@x.com", name: "Cards"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, user} = App.Users.upsert_allowed("cards@x.com")
    %{uid: user.id}
  end

  test "a turn's cards persist and read back (string keys, as on the wire)", %{uid: uid} do
    {:ok, _} =
      Memory.persist_turn(%{
        user_id: uid,
        user_text: "weather?",
        brain_text: "Sunny and 72.",
        cards: [@card]
      })

    assert [turn] = Memory.recent_turns(uid)

    assert [%{"type" => "weather", "temp" => "72°", "details" => [%{"label" => "Wind"}]}] =
             turn.cards
  end

  test "a turn without cards stores NULL", %{uid: uid} do
    {:ok, _} = Memory.persist_turn(%{user_id: uid, user_text: "hi", brain_text: "hello"})
    assert [%{cards: nil}] = Memory.recent_turns(uid)
  end

  test "the brain's history contents are identical with or without cards", %{uid: uid} do
    {:ok, _} =
      Memory.persist_turn(%{
        user_id: uid,
        user_text: "weather?",
        brain_text: "Sunny.",
        cards: [@card]
      })

    with_cards = Gemini.build_contents(%{recent: Memory.recent_turns(uid)}, "and tomorrow?")

    without =
      Gemini.build_contents(
        %{recent: Enum.map(Memory.recent_turns(uid), &%{&1 | cards: nil})},
        "and tomorrow?"
      )

    assert with_cards == without
    refute inspect(with_cards) =~ "Lakeview"
  end

  test "the dashboard's saved-history rows ignore cards (text only, no crash)", %{uid: uid} do
    {:ok, turn} =
      Memory.persist_turn(%{
        user_id: uid,
        user_text: "weather?",
        brain_text: "Sunny.",
        cards: [@card]
      })

    assert AppWeb.Dashboard.Mirror.history_rows(Memory.recent_turns(uid)) == [
             %{id: "h-#{turn.id}-you", kind: :you, text: "weather?"},
             %{id: "h-#{turn.id}-brain", kind: :brain, text: "Sunny."}
           ]
  end

  test "the embedded text and the full-text index never see card JSON", %{uid: uid} do
    {:ok, turn} =
      Memory.persist_turn(%{
        user_id: uid,
        user_text: "weather?",
        brain_text: "Sunny.",
        cards: [@card]
      })

    refute Memory.embed_text_for(turn) =~ "Lakeview"
    # turns_fts indexes user_text + brain_text only, so a word that exists ONLY in the card
    # JSON finds nothing.
    assert Memory.search_turns(uid, "Lakeview") == []
    assert [_] = Memory.search_turns(uid, "Sunny")
  end
end
