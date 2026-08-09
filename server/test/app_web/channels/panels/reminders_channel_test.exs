defmodule AppWeb.Panels.RemindersChannelTest do
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

  defp fired!(attrs) do
    {:ok, r} = Reminders.create(Map.merge(%{due_at: at(-60)}, attrs))
    {:ok, r} = Reminders.mark_fired(r)
    r
  end

  defp join!(socket, alice), do: subscribe_and_join(socket, "panel:reminders:#{alice.id}", %{})

  test "join pushes both lists, each in the server's order", %{socket: socket, alice: alice} do
    {:ok, _} = Reminders.create(%{body: "later", due_at: at(7200), user_id: alice.id})
    {:ok, _} = Reminders.create(%{body: "soon", due_at: at(3600), user_id: alice.id})
    fired!(%{body: "bins out", user_id: alice.id})

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{due: due, upcoming: upcoming}
    assert Enum.map(due, & &1.body) == ["bins out"]
    # list_upcoming is due_at asc; the client renders in the order it is given.
    assert Enum.map(upcoming, & &1.body) == ["soon", "later"]
  end

  test "a row carries rendered display strings, not raw timestamps",
       %{socket: socket, alice: alice} do
    {:ok, _} =
      Reminders.create(%{
        body: "bins out",
        # Fixed rather than relative so the expected due_label below is a literal
        # string, but far enough out that it stays in list_upcoming's due_at >= now
        # window for the life of this suite.
        due_at: ~U[2027-01-05 23:30:00Z],
        user_id: alice.id,
        household: true,
        kind: "followup",
        recurrence: %{"freq" => "weekly", "byday" => ["tue"]}
      })

    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{upcoming: [row]}

    assert row.id
    assert row.body == "bins out"
    assert row.due_label == "Jan 5 5:30pm"
    assert row.recurrence_label == "every Tue"
    assert row.household == true
    assert row.kind == "followup"
    refute Map.has_key?(row, :due_at)
  end

  test "a one-shot has no recurrence label", %{socket: socket, alice: alice} do
    {:ok, _} = Reminders.create(%{body: "call the vet", due_at: at(3600), user_id: alice.id})
    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{upcoming: [row]}
    assert row.recurrence_label == nil
  end

  test "a change on the user's own topic re-pushes state", %{socket: socket, alice: alice} do
    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{upcoming: []}

    {:ok, _} = Reminders.create(%{body: "new one", due_at: at(3600), user_id: alice.id})
    assert_push "state", %{upcoming: [%{body: "new one"}]}
  end

  test "a change on the HOUSEHOLD topic re-pushes state", %{
    socket: socket,
    alice: alice,
    bob: bob
  } do
    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{upcoming: []}

    # Bob creates a shared reminder; broadcast_changed/2 fans it out to
    # reminders:household, which Alice's panel is subscribed to.
    {:ok, _} =
      Reminders.create(%{body: "shared bins", due_at: at(3600), user_id: bob.id, household: true})

    assert_push "state", %{upcoming: [%{body: "shared bins"}]}
  end

  test "the topic suffix is ignored — the state is the TOKEN's user",
       %{socket: socket, alice: alice, bob: bob} do
    {:ok, _} = Reminders.create(%{body: "alice's", due_at: at(3600), user_id: alice.id})
    {:ok, _} = Reminders.create(%{body: "bob's", due_at: at(3600), user_id: bob.id})

    {:ok, _reply, _socket} = subscribe_and_join(socket, "panel:reminders:#{bob.id}", %{})
    assert_push "state", %{upcoming: [%{body: "alice's"}]}
  end
end
