defmodule AppWeb.Panels.SettingsChannelTest do
  # async: false — SQLite is single-writer and these tests write users.
  use AppWeb.ChannelCase, async: false

  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "alice@x.com", name: "Alice"},
      %{email: "bob@x.com", name: "Bob"}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, alice} = Users.upsert_allowed("alice@x.com")
    {:ok, bob} = Users.upsert_allowed("bob@x.com")
    token = AppWeb.UserAuth.socket_token(alice.id)
    {:ok, socket} = connect(AppWeb.UserSocket, %{"token" => token})
    %{socket: socket, alice: alice, bob: bob}
  end

  defp join!(socket, user), do: subscribe_and_join(socket, "panel:settings:#{user.id}", %{})

  test "join pushes the full pref set", %{socket: socket, alice: alice} do
    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", state
    assert is_boolean(state.default_abi)
    assert is_boolean(state.default_ptt)
    assert is_boolean(state.voice_activation)
    assert is_integer(state.relock_seconds)
    assert state.app_version == App.version()
  end

  test "briefing_time is nil when the morning briefing is off", %{socket: socket, alice: alice} do
    {:ok, _} = Users.update_prefs(alice, %{briefing_time: nil})
    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{briefing_time: nil}
  end

  test "briefing_time carries the stored time when it is on", %{socket: socket, alice: alice} do
    {:ok, _} = Users.update_prefs(alice, %{briefing_time: "07:30"})
    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{briefing_time: "07:30"}
  end

  test "the state is the TOKEN's user, not the topic's", %{socket: socket, alice: alice, bob: bob} do
    {:ok, _} = Users.update_prefs(alice, %{relock_seconds: 11})
    {:ok, _} = Users.update_prefs(bob, %{relock_seconds: 29})

    # Alice's socket asking for Bob's topic still gets Alice's prefs.
    {:ok, _reply, _socket} = subscribe_and_join(socket, "panel:settings:#{bob.id}", %{})
    assert_push "state", %{relock_seconds: 11}
  end
end
