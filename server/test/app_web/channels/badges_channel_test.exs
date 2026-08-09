defmodule AppWeb.BadgesChannelTest do
  # async: false — SQLite is single-writer and these tests write reminders.
  use AppWeb.ChannelCase, async: false

  alias App.{Reminders, Users}

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

  defp at(offset_s),
    do: DateTime.utc_now() |> DateTime.add(offset_s, :second) |> DateTime.truncate(:second)

  # A reminder that has FIRED but not been acknowledged — what the badge counts.
  defp fired!(attrs) do
    {:ok, r} = Reminders.create(Map.merge(%{due_at: at(-60)}, attrs))
    {:ok, r} = Reminders.mark_fired(r)
    r
  end

  test "the count arrives on join", %{socket: socket, alice: alice} do
    fired!(%{body: "bins out", user_id: alice.id})
    {:ok, _reply, _socket} = subscribe_and_join(socket, "badges:#{alice.id}", %{})
    assert_push "badges", %{reminders: 1}
  end

  test "a change re-pushes the count", %{socket: socket, alice: alice} do
    {:ok, _reply, _socket} = subscribe_and_join(socket, "badges:#{alice.id}", %{})
    assert_push "badges", %{reminders: 0}

    r = fired!(%{body: "bins out", user_id: alice.id})
    Reminders.broadcast_changed(alice.id, false)
    assert_push "badges", %{reminders: 1}

    {:ok, _} = Reminders.acknowledge(r)
    assert_push "badges", %{reminders: 0}
  end

  test "a fired reminder re-pushes the count", %{socket: socket, alice: alice} do
    {:ok, _reply, _socket} = subscribe_and_join(socket, "badges:#{alice.id}", %{})
    assert_push "badges", %{reminders: 0}

    r = fired!(%{body: "bins out", user_id: alice.id})
    Phoenix.PubSub.broadcast(App.PubSub, "reminders:#{alice.id}", {:reminder_due, r})
    assert_push "badges", %{reminders: 1}
  end

  test "another user's HOUSEHOLD reminder counts; their private one does not",
       %{socket: socket, alice: alice, bob: bob} do
    fired!(%{body: "bob's own", user_id: bob.id})
    fired!(%{body: "shared bins", user_id: bob.id, household: true})

    {:ok, _reply, _socket} = subscribe_and_join(socket, "badges:#{alice.id}", %{})
    assert_push "badges", %{reminders: 1}
  end

  test "the topic suffix is ignored — the count is the TOKEN's user", %{
    socket: socket,
    alice: alice,
    bob: bob
  } do
    fired!(%{body: "alice's", user_id: alice.id})
    # Alice's socket asking for Bob's topic still gets Alice's count.
    {:ok, _reply, _socket} = subscribe_and_join(socket, "badges:#{bob.id}", %{})
    assert_push "badges", %{reminders: 1}
  end

  test "an unmatched event is refused, not fatal to the channel",
       %{socket: socket, alice: alice} do
    {:ok, _reply, socket} = subscribe_and_join(socket, "badges:#{alice.id}", %{})
    assert_push "badges", %{reminders: 0}

    ref = push(socket, "nonsense", %{"whatever" => 1})
    assert_reply ref, :error, %{reason: "bad_request"}

    # The channel process is still alive: a subsequent broadcast still lands
    # rather than the badge silently going stale.
    fired!(%{body: "bins out", user_id: alice.id})
    Reminders.broadcast_changed(alice.id, false)
    assert_push "badges", %{reminders: 1}
  end
end
