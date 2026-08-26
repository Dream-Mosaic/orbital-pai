defmodule AppWeb.Panels.BooksChannelTest do
  # async: false — SQLite is single-writer and these tests write lists/plants.
  use AppWeb.ChannelCase, async: false

  alias App.{Garden, Lists, Repo, Users}

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

  defp join!(socket, user), do: subscribe_and_join(socket, "panel:books:#{user.id}", %{})

  defp list!(user, name, household \\ false),
    do: Lists.find_or_create_list(%{user_id: user.id, household: household}, name)

  defp pick!(user, key) do
    {:ok, u} = Users.update_prefs(user, %{books_last_book: key})
    u
  end

  test "join pushes books name-sorted with the garden last", %{socket: socket, alice: alice} do
    list!(alice, "Zucchini")
    list!(alice, "Apples")

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{books: books}
    assert Enum.map(books, & &1.label) == ["Apples", "Zucchini", "Garden"]
    assert List.last(books).kind == "garden"
  end

  test "the icon on the wire is the bare asset name, not the hero- class",
       %{socket: socket, alice: alice} do
    list!(alice, "Groceries")
    list!(alice, "Projects")

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{books: books}

    assert Enum.map(books, & &1.icon) ==
             ["shopping-cart", "clipboard-document-list", "sun"]
  end

  test "current_key comes from the pref", %{socket: socket, alice: alice} do
    list = list!(alice, "Apples")
    alice = pick!(alice, "list:#{list.id}")

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{current_key: key, list: body}
    assert key == "list:#{list.id}"
    assert body.name == "Apples"
  end

  test "a stale key falls back to the HOUSEHOLD GROCERIES list, not merely the first book",
       %{socket: socket, alice: alice} do
    # The two candidate fallbacks must DISAGREE: name order puts "Apples"
    # first, but the rule (conversation_live.ex:595-600) prefers a household
    # list literally named "groceries". A fixture with Groceries alphabetically
    # first would let `List.first(books)` pass by coincidence.
    list!(alice, "Apples")
    groceries = list!(alice, "Groceries", true)
    pick!(alice, "list:999999")

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{current_key: key}
    assert key == "list:#{groceries.id}"
  end

  test "with no lists at all, the fallback is the garden book", %{socket: socket, alice: alice} do
    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{current_key: "garden", list: nil, garden: garden}
    assert garden.active == []
  end

  test "items come back unchecked-first — insertion order must not pass this",
       %{socket: socket, alice: alice} do
    # Insert the CHECKED item first, so preload order (inserted_at, id) and
    # sorted order disagree. A missing sort yields ["milk", "eggs"].
    list = list!(alice, "Apples")
    {:ok, milk} = Lists.add_item(list, "milk")
    {:ok, _} = Lists.check_item(milk)
    {:ok, _eggs} = Lists.add_item(list, "eggs")
    pick!(alice, "list:#{list.id}")

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{list: body}
    assert Enum.map(body.items, & &1.text) == ["eggs", "milk"]
    assert Enum.map(body.items, & &1.checked) == [false, true]
  end

  test "past seasons come back newest-first as a LIST, and each carries its plants",
       %{socket: socket, alice: alice} do
    # Elixir enumerates a small map in sorted key order, so an unsorted or
    # ascending implementation yields ["2025", "2026"] — the opposite.
    {:ok, old} = Garden.add_plant(%{user_id: alice.id, household: false}, %{name: "Beans"})
    {:ok, new} = Garden.add_plant(%{user_id: alice.id, household: false}, %{name: "Peas"})
    {:ok, _} = Garden.archive_plant(old, "2025")
    {:ok, _} = Garden.archive_plant(new, "2026")
    pick!(alice, "garden")

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{garden: garden}
    assert is_list(garden.past)
    assert Enum.map(garden.past, & &1.season) == ["2026", "2025"]
    assert Enum.map(hd(garden.past).plants, & &1.name) == ["Peas"]
  end

  test "an active plant carries its meta line and dated notes",
       %{socket: socket, alice: alice} do
    {:ok, plant} =
      Garden.add_plant(%{user_id: alice.id, household: true}, %{
        name: "Tomatoes",
        species: "Roma",
        location: "back bed",
        count: 5,
        planted_on: ~D[2026-07-11]
      })

    {:ok, _} = Garden.add_note(plant, "first flowers", ~D[2026-07-20])
    pick!(alice, "garden")

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{garden: %{active: [p]}}
    assert p.meta == "Roma · back bed · 5 plants · planted Jul 11"
    assert p.household == true
    assert [%{body: "first flowers", noted: "Jul 20"}] = p.notes
  end

  test "clear_confirm is type-aware", %{socket: socket, alice: alice} do
    list = list!(alice, "Apples")
    pick!(alice, "list:#{list.id}")
    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{clear_confirm: confirm}
    assert confirm == "Clear everything off Apples? The list stays, just empty."

    pick!(alice, "garden")
    token = AppWeb.UserAuth.socket_token(alice.id)
    {:ok, socket2} = connect(AppWeb.UserSocket, %{"token" => token})
    {:ok, _reply, _socket} = join!(socket2, alice)
    assert_push "state", %{clear_confirm: confirm2}

    assert confirm2 ==
             "Close out this season? Active plants move to Past seasons — nothing is deleted."
  end

  test "the state is the TOKEN's user, not the topic's", %{socket: socket, alice: alice, bob: bob} do
    list!(bob, "Bob's Errands")
    list!(alice, "Apples")

    # Alice's token, Bob's id in the topic. The suffix is decoration.
    {:ok, _reply, _socket} = subscribe_and_join(socket, "panel:books:#{bob.id}", %{})

    assert_push "state", %{books: books}
    assert Enum.map(books, & &1.label) == ["Apples", "Garden"]
  end

  test "a list change from anywhere re-pushes state through the subscription",
       %{socket: socket, alice: alice} do
    list = list!(alice, "Apples")
    pick!(alice, "list:#{list.id}")

    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{list: %{items: []}}

    # Nothing here touches the channel: this is the LiveView's / a voice tool's
    # write. It must still reach the panel.
    {:ok, _} = Lists.add_item(list, "milk")

    assert_push "state", %{list: %{items: [%{text: "milk"}]}}
  end

  test "a garden change from anywhere re-pushes state through the subscription",
       %{socket: socket, alice: alice} do
    pick!(alice, "garden")
    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{garden: %{active: []}}

    {:ok, _} = Garden.add_plant(%{user_id: alice.id, household: false}, %{name: "Peas"})

    assert_push "state", %{garden: %{active: [%{name: "Peas"}]}}
  end

  test "an unknown event is bad_request and does not crash the channel",
       %{socket: socket, alice: alice} do
    {:ok, _reply, sock} = join!(socket, alice)
    assert_push "state", %{}
    ref = push(sock, "nonsense", %{})
    assert_reply ref, :error, %{reason: "bad_request"}
  end

  test "writes are authorised by the TOKEN's user, not the topic suffix",
       %{socket: socket, alice: alice, bob: bob} do
    mine = list!(alice, "Apples")
    theirs = list!(bob, "Bob's Errands")
    {:ok, their_item} = Lists.add_item(theirs, "secret")

    # Alice's token, Bob's id in the topic — the same client-reachable state as
    # "the state is the TOKEN's user, not the topic's" above, now exercised
    # against the WRITE path. The `list writes` describe block's setup always
    # joins a user's OWN topic, which is exactly why this gap needs its own
    # top-level test: an implementation that authorises by the (attacker-
    # controlled) topic suffix instead of the token would pass every test in
    # that block.
    {:ok, _reply, sock} = subscribe_and_join(socket, "panel:books:#{bob.id}", %{})
    assert_push "state", %{}

    ref = push(sock, "add_item", %{"list_id" => theirs.id, "text" => "milk"})
    assert_reply ref, :error, %{reason: "bad_request"}

    ref = push(sock, "toggle_item", %{"id" => their_item.id})
    assert_reply ref, :error, %{reason: "bad_request"}

    assert [%{text: "secret", checked_at: nil}] = Lists.with_items(theirs).items
    refute_push "state", %{}, 100

    # Load-bearing: without this half, an implementation that denies EVERY
    # write (regardless of ownership) would also pass the assertions above.
    # Alice's OWN list must still be actionable from this same socket/topic.
    ref = push(sock, "add_item", %{"list_id" => mine.id, "text" => "eggs"})
    assert_reply ref, :ok
    assert_push "state", %{list: %{items: [%{text: "eggs"}]}}
    assert Enum.map(Lists.with_items(mine).items, & &1.text) == ["eggs"]
  end

  test "a user deleted between connect and join does not crash the channel",
       %{socket: socket, alice: alice} do
    # The socket already authenticated as Alice at connect/2 (setup, above).
    # Deleting the row here — after connect, before join — is the cheapest
    # honest way to put a live socket.assigns.user_id behind a Users.get/1
    # that returns nil, the same race state/1's guard defends against.
    {:ok, _} = Repo.delete(alice)

    {:ok, _reply, sock} = join!(socket, alice)
    refute_push "state", _, 200

    # The channel process must still be alive and answering, not crashed.
    ref = push(sock, "nonsense", %{})
    assert_reply ref, :error, %{reason: "bad_request"}

    # The three book-level handlers (clear_book, select_book, new_list) each
    # independently call Users.get/1 and dereference the result — a nil user
    # must reply bad_request, not crash the channel with a BadMapError.
    ref = push(sock, "clear_book", %{})
    assert_reply ref, :error, %{reason: "bad_request"}

    ref = push(sock, "select_book", %{"key" => "garden"})
    assert_reply ref, :error, %{reason: "bad_request"}

    ref = push(sock, "new_list", %{"name" => "Camping"})
    assert_reply ref, :error, %{reason: "bad_request"}
  end

  test "garden and book-level writes are authorised by the TOKEN's user, not the topic suffix",
       %{socket: socket, alice: alice, bob: bob} do
    mine = list!(alice, "Apples")
    {:ok, theirs} = Garden.add_plant(%{user_id: bob.id, household: false}, %{name: "Kale"})
    their_list = list!(bob, "Bob's Errands")

    # Alice's token, Bob's id in the topic — the same client-reachable state as
    # "writes are authorised by the TOKEN's user" above, now exercised against
    # a garden write and the two non-broadcasting book-level writes. The
    # "garden writes" and "the two writes that do NOT broadcast" describe
    # blocks' setups always join a user's OWN topic, which is exactly why this
    # gap needs its own top-level test: an implementation that authorises by
    # the (attacker-controlled) topic suffix instead of the token would pass
    # every test in those blocks.
    {:ok, _reply, sock} = subscribe_and_join(socket, "panel:books:#{bob.id}", %{})
    assert_push "state", %{}

    ref = push(sock, "archive_plant", %{"id" => theirs.id})
    assert_reply ref, :error, %{reason: "bad_request"}
    assert [%{name: "Kale"}] = Garden.garden(bob.id).active

    ref = push(sock, "select_book", %{"key" => "list:#{their_list.id}"})
    assert_reply ref, :error, %{reason: "bad_request"}

    # Load-bearing: without this half, an implementation that denies EVERY
    # write (regardless of ownership) would also pass the assertions above.
    # Alice's OWN write must still succeed from this same socket/topic.
    ref = push(sock, "select_book", %{"key" => "list:#{mine.id}"})
    assert_reply ref, :ok
    assert_push "state", %{current_key: key, list: %{name: "Apples"}}
    assert key == "list:#{mine.id}"
  end

  describe "list writes" do
    setup %{socket: socket, alice: alice} do
      list = Lists.find_or_create_list(%{user_id: alice.id, household: false}, "Apples")
      {:ok, u} = Users.update_prefs(alice, %{books_last_book: "list:#{list.id}"})
      {:ok, _reply, sock} = subscribe_and_join(socket, "panel:books:#{u.id}", %{})
      assert_push "state", %{}
      %{sock: sock, list: list, alice: u}
    end

    test "add_item appends and the panel sees it", %{sock: sock, list: list} do
      ref = push(sock, "add_item", %{"list_id" => list.id, "text" => "  milk  "})
      assert_reply ref, :ok
      assert_push "state", %{list: %{items: [%{text: "milk", checked: false}]}}
    end

    test "add_item with a blank text is bad_request and writes nothing",
         %{sock: sock, list: list} do
      ref = push(sock, "add_item", %{"list_id" => list.id, "text" => "   "})
      assert_reply ref, :error, %{reason: "bad_request"}
      refute_push "state", %{}, 100
      assert Lists.with_items(list).items == []
    end

    test "toggle_item checks, then unchecks", %{sock: sock, list: list} do
      {:ok, item} = Lists.add_item(list, "milk")
      assert_push "state", %{}

      ref = push(sock, "toggle_item", %{"id" => item.id})
      assert_reply ref, :ok
      assert_push "state", %{list: %{items: [%{checked: true}]}}

      ref = push(sock, "toggle_item", %{"id" => item.id})
      assert_reply ref, :ok
      assert_push "state", %{list: %{items: [%{checked: false}]}}
    end

    test "clear_done removes only the checked items", %{sock: sock, list: list} do
      {:ok, milk} = Lists.add_item(list, "milk")
      {:ok, _eggs} = Lists.add_item(list, "eggs")
      {:ok, _} = Lists.check_item(milk)

      ref = push(sock, "clear_done", %{"list_id" => list.id})
      assert_reply ref, :ok
      assert_push "state", %{list: %{items: [%{text: "eggs"}]}}
    end

    test "delete_list removes it and the panel falls back to another book",
         %{sock: sock, list: list} do
      ref = push(sock, "delete_list", %{"list_id" => list.id})
      assert_reply ref, :ok
      assert_push "state", %{current_key: "garden", books: books, list: nil}
      assert Enum.map(books, & &1.label) == ["Garden"]
    end

    test "another user's list is bad_request and is NOT deleted",
         %{sock: sock, bob: bob} do
      theirs = Lists.find_or_create_list(%{user_id: bob.id, household: false}, "Bob's")

      for {event, payload} <- [
            {"add_item", %{"list_id" => theirs.id, "text" => "x"}},
            {"clear_done", %{"list_id" => theirs.id}},
            {"delete_list", %{"list_id" => theirs.id}}
          ] do
        ref = push(sock, event, payload)
        assert_reply ref, :error, %{reason: "bad_request"}
      end

      refute_push "state", %{}, 100
      assert Lists.list_visible(bob.id) |> Enum.map(& &1.name) == ["Bob's"]
    end

    test "another user's ITEM is bad_request and stays unchecked", %{sock: sock, bob: bob} do
      theirs = Lists.find_or_create_list(%{user_id: bob.id, household: false}, "Bob's")
      {:ok, item} = Lists.add_item(theirs, "secret")

      ref = push(sock, "toggle_item", %{"id" => item.id})
      assert_reply ref, :error, %{reason: "bad_request"}
      assert [%{checked_at: nil}] = Lists.with_items(theirs).items
    end

    test "a HOUSEHOLD list owned by someone else IS actionable — visible, not owned",
         %{sock: sock, bob: bob} do
      shared = Lists.find_or_create_list(%{user_id: bob.id, household: true}, "Household")

      ref = push(sock, "add_item", %{"list_id" => shared.id, "text" => "bread"})
      assert_reply ref, :ok
      assert [%{text: "bread"}] = Lists.with_items(shared).items
    end
  end

  describe "garden writes" do
    setup %{socket: socket, alice: alice} do
      {:ok, plant} =
        Garden.add_plant(%{user_id: alice.id, household: false}, %{name: "Tomatoes"})

      {:ok, u} = Users.update_prefs(alice, %{books_last_book: "garden"})
      {:ok, _reply, sock} = subscribe_and_join(socket, "panel:books:#{u.id}", %{})
      assert_push "state", %{}
      %{sock: sock, plant: plant, alice: u}
    end

    test "add_note appends a dated note", %{sock: sock, plant: plant} do
      ref = push(sock, "add_note", %{"plant_id" => plant.id, "body" => "  sprouting  "})
      assert_reply ref, :ok
      assert_push "state", %{garden: %{active: [%{notes: [%{body: "sprouting"}]}]}}
    end

    test "add_note with a blank body is bad_request and writes nothing",
         %{sock: sock, plant: plant} do
      ref = push(sock, "add_note", %{"plant_id" => plant.id, "body" => "  "})
      assert_reply ref, :error, %{reason: "bad_request"}
      refute_push "state", %{}, 100
    end

    test "archive_plant moves it into past seasons, revive_plant brings it back",
         %{sock: sock, plant: plant} do
      ref = push(sock, "archive_plant", %{"id" => plant.id})
      assert_reply ref, :ok
      assert_push "state", %{garden: %{active: [], past: [%{plants: [%{name: "Tomatoes"}]}]}}

      ref = push(sock, "revive_plant", %{"id" => plant.id})
      assert_reply ref, :ok
      assert_push "state", %{garden: %{active: [%{name: "Tomatoes"}], past: []}}
    end

    test "another user's plant is bad_request and stays active", %{sock: sock, bob: bob} do
      {:ok, theirs} = Garden.add_plant(%{user_id: bob.id, household: false}, %{name: "Kale"})

      for {event, payload} <- [
            {"add_note", %{"plant_id" => theirs.id, "body" => "x"}},
            {"archive_plant", %{"id" => theirs.id}},
            {"revive_plant", %{"id" => theirs.id}}
          ] do
        ref = push(sock, event, payload)
        assert_reply ref, :error, %{reason: "bad_request"}
      end

      assert [%{name: "Kale"}] = Garden.garden(bob.id).active
    end

    test "revive_plant on an ACTIVE plant is bad_request", %{sock: sock, plant: plant} do
      # own_plant/3 looks only in the ARCHIVED pool for a revive; a plant that
      # is still active is not in the search space, exactly like archiving an
      # already-archived one below. Merging the two pools would let this
      # through.
      ref = push(sock, "revive_plant", %{"id" => plant.id})
      assert_reply ref, :error, %{reason: "bad_request"}
      assert [%{name: "Tomatoes"}] = Garden.garden(plant.user_id).active
    end

    test "archive_plant on an ALREADY-ARCHIVED plant is bad_request", %{sock: sock, alice: alice} do
      {:ok, dormant} = Garden.add_plant(%{user_id: alice.id, household: false}, %{name: "Basil"})
      {:ok, dormant} = Garden.archive_plant(dormant)

      ref = push(sock, "archive_plant", %{"id" => dormant.id})
      assert_reply ref, :error, %{reason: "bad_request"}

      assert Garden.garden(alice.id).archived_by_season
             |> Enum.flat_map(fn {_season, ps} -> ps end)
             |> Enum.any?(&(&1.id == dormant.id))
    end

    test "a HOUSEHOLD plant owned by someone else IS actionable — visible, not owned",
         %{sock: sock, bob: bob} do
      {:ok, shared} = Garden.add_plant(%{user_id: bob.id, household: true}, %{name: "Mint"})

      ref = push(sock, "add_note", %{"plant_id" => shared.id, "body" => "watered"})
      assert_reply ref, :ok

      assert %{notes: [%{body: "watered"}]} =
               Enum.find(Garden.garden(bob.id).active, &(&1.id == shared.id))
    end
  end

  describe "clear_book" do
    test "on a list book it empties the items and KEEPS the list",
         %{socket: socket, alice: alice} do
      list = Lists.find_or_create_list(%{user_id: alice.id, household: false}, "Apples")
      {:ok, _} = Lists.add_item(list, "milk")
      {:ok, u} = Users.update_prefs(alice, %{books_last_book: "list:#{list.id}"})
      {:ok, _reply, sock} = subscribe_and_join(socket, "panel:books:#{u.id}", %{})
      assert_push "state", %{}

      ref = push(sock, "clear_book", %{})
      assert_reply ref, :ok
      assert_push "state", %{list: %{name: "Apples", items: []}}
      assert Lists.list_visible(u.id) |> Enum.map(& &1.name) == ["Apples"]
    end

    test "on the garden book it closes out the season", %{socket: socket, alice: alice} do
      # A list book must also exist, so the FIRST book (lists name-sorted, then
      # garden last) is NOT the garden — with zero lists, `List.first(books)`
      # and the correct `current_book/2` resolution are indistinguishable.
      _list = Lists.find_or_create_list(%{user_id: alice.id, household: false}, "Apples")
      {:ok, _} = Garden.add_plant(%{user_id: alice.id, household: false}, %{name: "Peas"})
      {:ok, u} = Users.update_prefs(alice, %{books_last_book: "garden"})
      {:ok, _reply, sock} = subscribe_and_join(socket, "panel:books:#{u.id}", %{})
      assert_push "state", %{}

      ref = push(sock, "clear_book", %{})
      assert_reply ref, :ok
      assert_push "state", %{garden: %{active: [], past: [%{plants: [%{name: "Peas"}]}]}}
    end

    test "a stale (already-deleted) list preference falls back instead of crashing",
         %{socket: socket, alice: alice} do
      # NOT a mid-flight race: `Books.clear/1`'s `{:error, :not_found}` arm
      # only fires for a list deleted BETWEEN `Books.for_user/1` and
      # `Books.clear/1` inside the SAME handle_in call — a window this test
      # cannot reach deterministically (no hook exists to pause the handler
      # mid-call). Deleting the list up front instead exercises the channel's
      # real defence for a stale pref: `current_book/2` re-resolves
      # `books_last_book` via `Books.resolve/2` on every call, so a deleted
      # list is simply absent from `Books.for_user/1`'s result and the pref
      # falls back BEFORE `Books.clear/1` ever sees the stale id — here, to
      # the household "Groceries" list (current_book/2's household-groceries
      # priority), which is the one that actually gets cleared.
      list = Lists.find_or_create_list(%{user_id: alice.id, household: false}, "Apples")
      groceries = Lists.find_or_create_list(%{user_id: alice.id, household: true}, "Groceries")
      {:ok, _} = Lists.add_item(groceries, "milk")
      {:ok, u} = Users.update_prefs(alice, %{books_last_book: "list:#{list.id}"})
      {:ok, _reply, sock} = subscribe_and_join(socket, "panel:books:#{u.id}", %{})
      assert_push "state", %{}

      {:ok, _} = Lists.delete_list(list)
      assert_push "state", %{}

      ref = push(sock, "clear_book", %{})
      assert_reply ref, :ok
      assert_push "state", %{list: %{name: "Groceries", items: []}}
    end
  end

  describe "the two writes that do NOT broadcast" do
    test "select_book switches the current book — the handler must push it itself",
         %{socket: socket, alice: alice} do
      list = Lists.find_or_create_list(%{user_id: alice.id, household: false}, "Apples")
      {:ok, u} = Users.update_prefs(alice, %{books_last_book: "garden"})
      {:ok, _reply, sock} = subscribe_and_join(socket, "panel:books:#{u.id}", %{})
      assert_push "state", %{current_key: "garden"}

      ref = push(sock, "select_book", %{"key" => "list:#{list.id}"})
      assert_reply ref, :ok
      # NOTHING broadcasts here (users.ex:86-88). Without the handler's own
      # push_state this assertion times out — that is the point of the test.
      assert_push "state", %{current_key: key, list: %{name: "Apples"}}
      assert key == "list:#{list.id}"
    end

    test "select_book survives a restart — the choice is persisted",
         %{socket: socket, alice: alice} do
      list = Lists.find_or_create_list(%{user_id: alice.id, household: false}, "Apples")
      {:ok, _reply, sock} = subscribe_and_join(socket, "panel:books:#{alice.id}", %{})
      assert_push "state", %{}

      ref = push(sock, "select_book", %{"key" => "list:#{list.id}"})
      assert_reply ref, :ok
      assert_push "state", %{}

      assert Users.get(alice.id).books_last_book == "list:#{list.id}"
    end

    test "select_book on a key that is not this user's is bad_request",
         %{socket: socket, alice: alice, bob: bob} do
      theirs = Lists.find_or_create_list(%{user_id: bob.id, household: false}, "Bob's")
      {:ok, _reply, sock} = subscribe_and_join(socket, "panel:books:#{alice.id}", %{})
      assert_push "state", %{}

      ref = push(sock, "select_book", %{"key" => "list:#{theirs.id}"})
      assert_reply ref, :error, %{reason: "bad_request"}
      assert Users.get(alice.id).books_last_book == nil
    end

    test "new_list creates it, makes it current, and the handler must push it itself",
         %{socket: socket, alice: alice, bob: bob} do
      {:ok, _reply, sock} = subscribe_and_join(socket, "panel:books:#{alice.id}", %{})
      assert_push "state", %{current_key: "garden"}

      ref = push(sock, "new_list", %{"name" => "  Camping  "})
      assert_reply ref, :ok
      # find_or_create_list/2 is the ONE mutating function in App.Lists with no
      # broadcast (lists.ex:19-43); nothing rides here either.
      assert_push "state",
                  %{current_key: key, books: books, list: %{name: "Camping", household: false}}

      assert Enum.map(books, & &1.label) == ["Camping", "Garden"]
      assert String.starts_with?(key, "list:")

      # Personal, never household (conversation_live.ex:263) — a household
      # list would be visible to every other user, so Bob must NOT see it.
      refute Enum.any?(Lists.list_visible(bob.id), &(&1.name == "Camping"))
    end

    test "new_list with a blank name is bad_request and creates nothing",
         %{socket: socket, alice: alice} do
      {:ok, _reply, sock} = subscribe_and_join(socket, "panel:books:#{alice.id}", %{})
      assert_push "state", %{}

      ref = push(sock, "new_list", %{"name" => "   "})
      assert_reply ref, :error, %{reason: "bad_request"}
      refute_push "state", %{}, 100
      assert Lists.list_visible(alice.id) == []
    end
  end
end
