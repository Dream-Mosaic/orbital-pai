defmodule AppWeb.VoiceChannelUnsavedTurnsTest do
  # A turn is persisted only when it ENDS, and an interrupted unanswered request only with the
  # turn that finally answers it. The `history` push is read from the DB, so a device that
  # (re)joins while a turn is still open used to get a thread stopping short of what was just
  # said — and with the brain stuck, it stayed that way (#32). The push now ends with the
  # session's unsaved turns. async: false — the Conversation runs in a supervised process
  # sharing the sandbox, with the global Mox stub answering its reflex.
  use AppWeb.ChannelCase, async: false

  alias App.Conversations.{Conversation, Sessions}
  alias App.Users

  setup do
    Mox.set_mox_global()
    Mox.stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "Right."} end)

    # Hold the fake brain's answer back, so the turn is still in flight when the device rejoins.
    Application.put_env(:app, :fake_brain_done_ms, 5_000)
    Application.put_env(:app, :allowed_users, [%{email: "bob@x.com", name: "Bob"}])

    on_exit(fn ->
      Application.delete_env(:app, :fake_brain_done_ms)
      Application.delete_env(:app, :allowed_users)
    end)

    {:ok, bob} = Users.upsert_allowed("bob@x.com")
    {:ok, bob} = Users.update_prefs(bob, %{voice_activation: false})
    App.Memory.persist_turn(%{user_id: bob.id, user_text: "q1", brain_text: "a1"})
    %{bob: bob}
  end

  defp join_voice(user, payload) do
    token = AppWeb.UserAuth.socket_token(user.id)
    {:ok, socket} = connect(AppWeb.UserSocket, %{"token" => token})
    {:ok, _reply, channel} = subscribe_and_join(socket, "voice:#{user.id}", payload)
    on_exit(fn -> Sessions.stop(to_string(user.id)) end)
    channel
  end

  defp session(user) do
    {:ok, pid} = Sessions.lookup(to_string(user.id))
    pid
  end

  test "a device that rejoins mid-turn gets the words still in flight", %{bob: bob} do
    join_voice(bob, %{"device_id" => "dev-a"})
    assert_push "history", %{turns: [%{you: "q1"}]}, 500

    Conversation.endpoint(session(bob), "what's the weather")
    assert_push "speak_start", %{source: :reflex}, 1_000

    # the app reopened: the same device, a fresh channel
    join_voice(bob, %{"device_id" => "dev-a"})

    assert_push "history", %{turns: [%{you: "q1", assistant: "a1"}, in_flight]}, 500
    assert %{you: "what's the weather", assistant: nil} = in_flight
  end

  test "an interrupted, unanswered request is in the history before the next turn answers it",
       %{bob: bob} do
    join_voice(bob, %{"device_id" => "dev-a"})
    assert_push "history", %{turns: [_]}, 500

    pid = session(bob)
    Conversation.endpoint(pid, "start claude on the scratchpad bug")
    assert_push "speak_start", %{source: :reflex}, 1_000
    Conversation.barge_in(pid)
    assert_push "stop_playback", _, 500

    join_voice(bob, %{"device_id" => "dev-a"})
    assert_push "history", %{turns: [_, carried]}, 500
    assert %{you: "start claude on the scratchpad bug", assistant: nil} = carried

    # The next utterance folds the carried request in: one unsaved turn, the words it persists as.
    Conversation.endpoint(pid, "the latter")
    assert_push "speak_start", %{source: :reflex}, 1_000

    join_voice(bob, %{"device_id" => "dev-a"})
    assert_push "history", %{turns: [_, merged]}, 500
    assert merged.you == "start claude on the scratchpad bug the latter"
  end

  test "a claim's replace history keeps the turn in flight", %{bob: bob} do
    join_voice(bob, %{"device_id" => "dev-a"})
    assert_push "state", %{bound: true}, 500
    s2 = join_voice(bob, %{"device_id" => "dev-b"})
    assert_push "state", %{bound: false}, 500

    Conversation.endpoint(session(bob), "what's the weather")
    assert_push "speak_start", %{source: :reflex}, 1_000

    push(s2, "wake_detected", %{})

    assert_push "bound", %{bound: true}, 500

    assert_push "history",
                %{turns: [%{you: "q1"}, %{you: "what's the weather"}], replace: true},
                500
  end

  test "an idle session adds nothing to the history", %{bob: bob} do
    join_voice(bob, %{"device_id" => "dev-a"})
    assert_push "history", %{turns: [_]}, 500

    join_voice(bob, %{"device_id" => "dev-a"})
    assert_push "history", %{turns: [%{you: "q1", assistant: "a1"}]}, 500
  end
end
