defmodule AppWeb.VoiceChannelHistoryCardsTest do
  # The `history` push carries each turn's persisted cards, so the thread rebuilt on launch,
  # reconnect or hand-off shows them again. async: false — the Conversation runs in a
  # supervised process sharing the sandbox.
  use AppWeb.ChannelCase, async: false

  alias App.Conversations.Sessions
  alias App.Users

  @card %{type: "list", title: "Groceries", items: [%{text: "milk", done: false}]}

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "bob@x.com", name: "Bob"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, bob} = Users.upsert_allowed("bob@x.com")
    {:ok, bob} = Users.update_prefs(bob, %{voice_activation: false})

    App.Memory.persist_turn(%{
      user_id: bob.id,
      user_text: "what's on the grocery list",
      brain_text: "Milk.",
      cards: [@card]
    })

    App.Memory.persist_turn(%{user_id: bob.id, user_text: "thanks", brain_text: "Any time."})
    %{bob: bob}
  end

  defp join_voice(user, payload) do
    token = AppWeb.UserAuth.socket_token(user.id)
    {:ok, socket} = connect(AppWeb.UserSocket, %{"token" => token})
    {:ok, _reply, channel} = subscribe_and_join(socket, "voice:#{user.id}", payload)
    on_exit(fn -> Sessions.stop(to_string(user.id)) end)
    channel
  end

  test "the join backfill carries each turn's cards; a card-less turn has no cards key", %{
    bob: bob
  } do
    join_voice(bob, %{})

    assert_push "history", %{turns: [carded, plain]}
    assert %{you: "what's on the grocery list", assistant: "Milk."} = carded
    # string keys: the JSON column hands back the wire shape the live `card` push has
    assert [%{"type" => "list", "title" => "Groceries", "items" => [%{"text" => "milk"}]}] =
             carded.cards

    # unchanged for a turn that showed no cards (the payload is what it always was)
    assert plain == Map.take(plain, [:you, :assistant, :at])
  end

  test "a claim's replace history carries the cards too", %{bob: bob} do
    join_voice(bob, %{"device_id" => "dev-a"})
    assert_push "state", %{bound: true}, 500

    s2 = join_voice(bob, %{"device_id" => "dev-b"})
    assert_push "state", %{bound: false}, 500

    push(s2, "wake_detected", %{})

    assert_push "bound", %{bound: true}, 500

    assert_push "history",
                %{turns: [%{cards: [%{"type" => "list"}]}, plain], replace: true},
                500

    refute Map.has_key?(plain, :cards)
  end
end
