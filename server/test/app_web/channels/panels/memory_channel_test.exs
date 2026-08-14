defmodule AppWeb.Panels.MemoryChannelTest do
  # async: false — SQLite is single-writer and these tests write users/facts.
  use AppWeb.ChannelCase, async: false

  alias App.Memory
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

  defp join!(socket, user), do: subscribe_and_join(socket, "panel:memory:#{user.id}", %{})

  test "join pushes summary and facts", %{socket: socket, alice: alice} do
    {:ok, _} = Memory.create_fact(%{content: "likes tea", source: "user", user_id: alice.id})

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", state
    assert is_binary(state.summary)
    assert [%{content: "likes tea"}] = state.facts
  end

  test "an absent summary crosses as \"\", not nil", %{socket: socket, alice: alice} do
    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{summary: ""}
  end

  test "facts arrive in list_facts/1's order", %{socket: socket, alice: alice} do
    {:ok, first} =
      Memory.create_fact(%{content: "likes tea", source: "user", user_id: alice.id})

    {:ok, second} =
      Memory.create_fact(%{content: "likes coffee", source: "user", user_id: alice.id})

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{facts: facts}
    assert Enum.map(facts, & &1.id) == [first.id, second.id]
  end

  test "a fact row carries exactly id, content, source", %{socket: socket, alice: alice} do
    {:ok, _} =
      Memory.create_fact(%{
        content: "likes tea",
        source: "user",
        category: "preferences",
        user_id: alice.id
      })

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{facts: [fact]}
    assert Map.keys(fact) |> Enum.sort() == Enum.sort([:id, :content, :source])
  end

  test "the state is the TOKEN's user, not the topic's", %{socket: socket, alice: alice, bob: bob} do
    {:ok, _} = Memory.create_fact(%{content: "alice's fact", source: "user", user_id: alice.id})
    {:ok, _} = Memory.create_fact(%{content: "bob's fact", source: "user", user_id: bob.id})

    # Alice's socket asking for Bob's topic still gets Alice's facts.
    {:ok, _reply, _socket} = subscribe_and_join(socket, "panel:memory:#{bob.id}", %{})

    assert_push "state", %{facts: [%{content: "alice's fact"}]}
  end

  # NOTE: App.Memory.create_fact/1 does NOT itself call broadcast_updated/0
  # (verified by reading server/lib/app/memory.ex: only reset/1, clear_turns/1,
  # forget/1, and replace_auto_facts/2 do — create_fact/1, delete_fact/1, and
  # put_summary/2 do not, contradicting this channel's own moduledoc and the
  # design spec). App.Memory is out of scope for this task, so rather than
  # write a test against brief-described behavior that does not exist, this
  # exercises the channel's actual re-push wiring (join/2's Memory.subscribe()
  # + handle_info(:memory_updated, _)) via the real broadcast API, with a
  # create_fact beforehand to prove the re-push carries FRESH data, not a
  # cached copy.
  test "a Memory.broadcast_updated/0 following a create_fact re-pushes fresh state",
       %{socket: socket, alice: alice} do
    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{facts: []}

    {:ok, _} = Memory.create_fact(%{content: "likes tea", source: "user", user_id: alice.id})
    Memory.broadcast_updated()

    assert_push "state", %{facts: [%{content: "likes tea"}]}
  end
end
