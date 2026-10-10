defmodule AppWeb.VoiceChannelTimersTest do
  # Timers ride voice:henry: every device of the user subscribes to "timers:<uid>" and gets a
  # fresh `timers` push after join and on every change. async: false — the Conversation runs
  # in a supervised process sharing the sandbox.
  use AppWeb.ChannelCase, async: false

  alias App.Conversations.Sessions
  alias App.Timers
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "alice@x.com", name: "Alice"},
      %{email: "bob@x.com", name: "Bob"}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, alice} = Users.upsert_allowed("alice@x.com")
    {:ok, bob} = Users.upsert_allowed("bob@x.com")
    {:ok, alice} = Users.update_prefs(alice, %{voice_activation: false})
    %{alice: alice, bob: bob}
  end

  defp join_voice(user) do
    token = AppWeb.UserAuth.socket_token(user.id)
    {:ok, socket} = connect(AppWeb.UserSocket, %{"token" => token})
    {:ok, _reply, channel} = subscribe_and_join(socket, "voice:#{user.id}", %{})
    on_exit(fn -> Sessions.stop(to_string(user.id)) end)
    channel
  end

  test "join pushes the user's active timers", %{alice: alice} do
    {:ok, t} = Timers.create(alice.id, 600, "pasta")
    _channel = join_voice(alice)

    assert_push "timers", %{timers: [timer]}
    assert %{id: id, label: "pasta", state: "running", duration_ms: 600_000} = timer
    assert id == t.id
    assert timer.remaining_ms > 590_000
  end

  test "join with no timers pushes an empty list (the strip hides)", %{alice: alice} do
    _channel = join_voice(alice)
    assert_push "timers", %{timers: []}
  end

  test "every change re-pushes the list; another user's changes don't", %{
    alice: alice,
    bob: bob
  } do
    _channel = join_voice(alice)
    assert_push "timers", %{timers: []}

    {:ok, _} = Timers.create(bob.id, 60, "bob's")
    refute_push "timers", _, 100

    {:ok, t} = Timers.create(alice.id, 60, "tea")
    assert_push "timers", %{timers: [%{label: "tea", state: "running"}]}

    {:ok, _} = Timers.fire(t.id)
    assert_push "timers", %{timers: [%{label: "tea", state: "ringing", remaining_ms: 0}]}
  end

  describe "dismiss_timer" do
    test "silences one of the user's own ringing timers", %{alice: alice} do
      {:ok, t} = Timers.create(alice.id, 60)
      {:ok, _} = Timers.fire(t.id)
      channel = join_voice(alice)
      assert_push "timers", %{timers: [_]}

      ref = push(channel, "dismiss_timer", %{"id" => t.id})
      assert_reply ref, :ok
      assert_push "timers", %{timers: []}
      assert Timers.list_active(alice.id) == []
    end

    test "never another user's timer", %{alice: alice, bob: bob} do
      {:ok, theirs} = Timers.create(bob.id, 60)
      {:ok, _} = Timers.fire(theirs.id)
      channel = join_voice(alice)

      ref = push(channel, "dismiss_timer", %{"id" => theirs.id})
      assert_reply ref, :error, %{reason: "not_found"}
      assert [%{state: "ringing"}] = Timers.list_active(bob.id)
    end

    test "an off-shape payload is refused, not crashed on", %{alice: alice} do
      channel = join_voice(alice)
      ref = push(channel, "dismiss_timer", %{"id" => "7"})
      assert_reply ref, :error, %{reason: "bad_request"}
    end
  end

  describe "cancel_timer" do
    test "cancels one of the user's own running timers", %{alice: alice} do
      {:ok, t} = Timers.create(alice.id, 600, "pasta")
      channel = join_voice(alice)
      assert_push "timers", %{timers: [_]}

      ref = push(channel, "cancel_timer", %{"id" => t.id})
      assert_reply ref, :ok
      assert_push "timers", %{timers: []}
    end

    test "never another user's timer", %{alice: alice, bob: bob} do
      {:ok, theirs} = Timers.create(bob.id, 600)
      channel = join_voice(alice)

      ref = push(channel, "cancel_timer", %{"id" => theirs.id})
      assert_reply ref, :error, %{reason: "not_found"}
      assert [%{state: "running"}] = Timers.list_active(bob.id)
    end

    test "an off-shape payload is refused, not crashed on", %{alice: alice} do
      channel = join_voice(alice)
      ref = push(channel, "cancel_timer", %{})
      assert_reply ref, :error, %{reason: "bad_request"}
    end
  end
end
