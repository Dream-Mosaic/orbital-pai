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

  # `create_fact/1` does NOT broadcast on its own — see the moduledoc: only
  # reset/1, clear_turns/1, forget/1 and replace_auto_facts/2 do, and every
  # other caller broadcasts once its own unit of work is done. So this drives
  # the real broadcast API, which is what the Updater does after a turn, and
  # writes a fact first to prove the re-push carries FRESH data rather than a
  # cached copy. The write handlers get their own coverage from Task 3 on.
  test "a Memory.broadcast_updated/0 following a create_fact re-pushes fresh state",
       %{socket: socket, alice: alice} do
    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{facts: []}

    {:ok, _} = Memory.create_fact(%{content: "likes tea", source: "user", user_id: alice.id})
    Memory.broadcast_updated()

    assert_push "state", %{facts: [%{content: "likes tea"}]}
  end

  # This test deliberately never calls Memory.broadcast_updated/0 itself — the
  # only way the second "state" push can arrive is the handler's own
  # broadcast. If that call were missing, the write would still persist and
  # the reply would still be :ok, but this assert_push would time out.
  test "save_summary persists and the handler's own broadcast re-pushes state",
       %{socket: socket, alice: alice} do
    {:ok, _reply, socket} = join!(socket, alice)
    assert_push "state", %{summary: ""}

    ref = push(socket, "save_summary", %{"summary" => "loves hiking"})
    assert_reply ref, :ok

    assert Memory.get_summary(alice.id).content == "loves hiking"
    assert_push "state", %{summary: "loves hiking"}
  end

  test "an empty summary is allowed (clearing it is legitimate)", %{socket: socket, alice: alice} do
    {:ok, _} = Memory.put_summary(alice.id, "old summary")
    {:ok, _reply, socket} = join!(socket, alice)
    assert_push "state", %{summary: "old summary"}

    ref = push(socket, "save_summary", %{"summary" => ""})
    assert_reply ref, :ok

    assert Memory.get_summary(alice.id).content == ""
    assert_push "state", %{summary: ""}
  end

  test "save_summary triggers exactly one state push, not two", %{socket: socket, alice: alice} do
    {:ok, _reply, socket} = join!(socket, alice)
    assert_push "state", _

    ref = push(socket, "save_summary", %{"summary" => "one push only"})
    assert_reply ref, :ok
    assert_push "state", %{summary: "one push only"}
    refute_push "state", _
  end

  test "add_fact creates a user fact that appears in the next state",
       %{socket: socket, alice: alice} do
    {:ok, _reply, socket} = join!(socket, alice)
    assert_push "state", %{facts: []}

    ref = push(socket, "add_fact", %{"content" => "likes tea"})
    assert_reply ref, :ok

    assert_push "state", %{facts: [%{content: "likes tea", source: "user"}]}
  end

  test "blank or whitespace-only add_fact content is bad_request and creates nothing",
       %{socket: socket, alice: alice} do
    {:ok, _reply, socket} = join!(socket, alice)
    assert_push "state", %{facts: []}

    for content <- ["", "   ", "\n"] do
      ref = push(socket, "add_fact", %{"content" => content})
      assert_reply ref, :error, %{reason: "bad_request"}
    end

    assert Memory.list_facts(alice.id) == []
  end

  # A rejected write must not broadcast. Without this, a stray
  # Memory.broadcast_updated/0 on the rejection branch wouldn't fail this test
  # in isolation the way the "exactly one push" test catches an extra push on
  # a SUCCESSFUL write — there'd be no baseline push to compare against, so it
  # has to assert an explicit absence instead.
  test "a rejected add_fact (blank or whitespace) produces no state push",
       %{socket: socket, alice: alice} do
    {:ok, _reply, socket} = join!(socket, alice)
    assert_push "state", %{facts: []}

    for content <- ["", "   "] do
      ref = push(socket, "add_fact", %{"content" => content})
      assert_reply ref, :error, %{reason: "bad_request"}
      refute_push "state", _, 200
    end
  end

  test "a non-string add_fact payload is bad_request", %{socket: socket, alice: alice} do
    {:ok, _reply, socket} = join!(socket, alice)
    assert_push "state", %{facts: []}

    ref = push(socket, "add_fact", %{"content" => 123})
    assert_reply ref, :error, %{reason: "bad_request"}

    assert Memory.list_facts(alice.id) == []
  end
end
