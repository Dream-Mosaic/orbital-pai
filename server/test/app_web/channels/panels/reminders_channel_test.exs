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

  describe "writes" do
    test "ack acknowledges a due reminder and a fresh state follows",
         %{socket: socket, alice: alice} do
      r = fired!(%{body: "bins out", user_id: alice.id})
      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", %{due: [%{body: "bins out"}]}

      ref = push(socket, "ack", %{"id" => r.id})
      assert_reply ref, :ok
      assert_push "state", %{due: []}
      # Exactly one re-push — the handler itself must NOT also call push_state;
      # broadcast_changed/2 is the only path, or a second "state" would sit here.
      refute_push "state", _
      assert Reminders.list_unacknowledged(alice.id) == []
    end

    test "ack of a reminder that is NOT the user's changes nothing",
         %{socket: socket, alice: alice, bob: bob} do
      # Bob's private, fired reminder. Alice can neither see nor touch it.
      theirs = fired!(%{body: "bob's own", user_id: bob.id})
      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", %{due: []}

      ref = push(socket, "ack", %{"id" => theirs.id})
      assert_reply ref, :error, %{reason: "not_found"}
      assert [%{body: "bob's own"}] = Reminders.list_unacknowledged(bob.id)
    end

    test "ack of an UPCOMING reminder is refused — it never fired",
         %{socket: socket, alice: alice} do
      {:ok, r} = Reminders.create(%{body: "call the vet", due_at: at(3600), user_id: alice.id})
      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", %{upcoming: [_]}

      ref = push(socket, "ack", %{"id" => r.id})
      assert_reply ref, :error, %{reason: "not_found"}
    end

    test "dismiss deletes an upcoming reminder", %{socket: socket, alice: alice} do
      {:ok, r} = Reminders.create(%{body: "call the vet", due_at: at(3600), user_id: alice.id})
      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", %{upcoming: [_]}

      ref = push(socket, "dismiss", %{"id" => r.id})
      assert_reply ref, :ok
      assert_push "state", %{upcoming: []}
      # Exactly one re-push — same invariant as ack: broadcast_changed/2 is the
      # only path, so a second "state" here would mean the handler double-pushed.
      refute_push "state", _
    end

    test "dismiss on a recurring row cancels the whole series",
         %{socket: socket, alice: alice} do
      # The row IS the series on the web, and the ✕ cancels it. Same here.
      {:ok, r} =
        Reminders.create(%{
          body: "bins out",
          due_at: at(3600),
          user_id: alice.id,
          recurrence: %{"freq" => "weekly"}
        })

      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", %{upcoming: [_]}

      ref = push(socket, "dismiss", %{"id" => r.id})
      assert_reply ref, :ok
      assert_push "state", %{upcoming: []}
      assert Reminders.list_upcoming(alice.id) == []
    end

    test "dismiss of a reminder that is NOT the user's changes nothing",
         %{socket: socket, alice: alice, bob: bob} do
      {:ok, theirs} = Reminders.create(%{body: "bob's", due_at: at(3600), user_id: bob.id})
      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", %{upcoming: []}

      ref = push(socket, "dismiss", %{"id" => theirs.id})
      assert_reply ref, :error, %{reason: "not_found"}
      assert [%{body: "bob's"}] = Reminders.list_upcoming(bob.id)
    end

    test "a HOUSEHOLD reminder owned by someone else can be dismissed",
         %{socket: socket, alice: alice, bob: bob} do
      # Scoping is "can the user see it", not "does the user own it" — both
      # list queries already include household rows.
      {:ok, shared} =
        Reminders.create(%{
          body: "shared bins",
          due_at: at(3600),
          user_id: bob.id,
          household: true
        })

      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", %{upcoming: [_]}

      ref = push(socket, "dismiss", %{"id" => shared.id})
      assert_reply ref, :ok
      # Alice is subscribed to reminders:household but NOT reminders:#{bob.id},
      # so bob's own-topic broadcast half is invisible to her — exactly one
      # push here, unlike the own-household case below.
      assert_push "state", %{upcoming: []}
      assert Reminders.list_upcoming(bob.id) == []
    end

    test "a write on the user's OWN household reminder pushes state twice",
         %{socket: socket, alice: alice} do
      # Alice's row is household:true, so broadcast_changed/2 (App.Reminders)
      # fans out on BOTH reminders:#{alice.id} and reminders:household — and
      # Alice's channel is subscribed to both (join/3), so it receives two
      # broadcasts for this one write and pushes `state` twice. Documented
      # here rather than left as a surprise; see the comment above
      # handle_in/3. Harmless at two users and NOT something this test (or
      # the channel) should try to de-duplicate.
      {:ok, r} =
        Reminders.create(%{
          body: "shared bins",
          due_at: at(3600),
          user_id: alice.id,
          household: true
        })

      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", %{upcoming: [_]}

      ref = push(socket, "dismiss", %{"id" => r.id})
      assert_reply ref, :ok
      assert_push "state", %{upcoming: []}
      assert_push "state", %{upcoming: []}
      refute_push "state", _
    end

    test "an off-shape payload is refused, not crashed on", %{socket: socket, alice: alice} do
      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", %{upcoming: []}

      ref = push(socket, "ack", %{"id" => "42"})
      assert_reply ref, :error, %{reason: "bad_request"}

      ref = push(socket, "dismiss", %{})
      assert_reply ref, :error, %{reason: "bad_request"}
    end

    test "an unmatched event is refused, not fatal to the channel",
         %{socket: socket, alice: alice} do
      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", %{upcoming: []}

      ref = push(socket, "nonsense", %{"whatever" => 1})
      assert_reply ref, :error, %{reason: "bad_request"}

      # The channel process is still alive: a legitimate call right after
      # still gets a reply rather than the join silently going dark.
      ref2 = push(socket, "ack", %{"id" => "42"})
      assert_reply ref2, :error, %{reason: "bad_request"}
    end
  end
end
