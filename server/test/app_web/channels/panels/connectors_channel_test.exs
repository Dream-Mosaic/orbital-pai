defmodule AppWeb.Panels.ConnectorsChannelTest do
  # async: false — SQLite is single-writer and these tests write google_accounts.
  use AppWeb.ChannelCase, async: false

  alias App.Google.Account
  alias App.Repo
  alias App.Users

  @cal_read "https://www.googleapis.com/auth/calendar.readonly"
  @cal_write "https://www.googleapis.com/auth/calendar.events"
  @gmail_read "https://www.googleapis.com/auth/gmail.readonly"

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

  defp join!(socket, user), do: subscribe_and_join(socket, "panel:connectors:#{user.id}", %{})

  # A connected account with an explicit scope string. `scope` is the single
  # source of truth for access (connectors.ex:47-56), so the fixture sets it
  # directly rather than going through the OAuth upsert.
  defp account!(user, email, scopes, opts \\ []) do
    {:ok, a} =
      %Account{}
      |> Account.changeset(%{
        user_id: user.id,
        email: email,
        refresh_token: "rt-#{email}",
        scope: Enum.join(["openid", "email" | scopes], " "),
        is_default: Keyword.get(opts, :is_default, false)
      })
      |> Repo.insert()

    a
  end

  test "join pushes one row per (account, granted connector)", %{socket: socket, alice: alice} do
    account!(alice, "alice-1@x.com", [@cal_read, @gmail_read])

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{connections: rows}
    assert length(rows) == 2
  end

  test "rows are sorted by {label, email} — a swapped sort key must fail this",
       %{socket: socket, alice: alice} do
    # Label order and email order are chosen to DISAGREE: "Gmail" < "Google
    # Calendar" alphabetically, but "aaa-calendar@x.com" < "zzz-gmail@x.com".
    # A {label, email} sort puts the gmail row first; a swapped {email, label}
    # sort puts the calendar row first instead. Using accounts whose emails
    # happen to already agree with the label order (as one might reach for
    # first, e.g. "aa@x.com" ahead of "alice-1@x.com") would let a swapped
    # key produce the identical output by coincidence — verified empirically
    # against this file's own history, so don't revert to that shape.
    account!(alice, "zzz-gmail@x.com", [@gmail_read])
    account!(alice, "aaa-calendar@x.com", [@cal_read])

    {:ok, _reply, _socket1} = join!(socket, alice)
    assert_push "state", %{connections: rows1}
    assert Enum.map(rows1, & &1.connector) == ["gmail", "calendar"]

    # Secondary key: within the SAME label, rows sort by email.
    account!(alice, "bbb-calendar@x.com", [@cal_read])

    {:ok, _reply, _socket2} = join!(socket, alice)
    assert_push "state", %{connections: rows2}

    calendar_emails =
      rows2
      |> Enum.filter(&(&1.connector == "calendar"))
      |> Enum.map(& &1.email)

    assert calendar_emails == ["aaa-calendar@x.com", "bbb-calendar@x.com"]
  end

  test "a row carries exactly the intended keys, and no token or scope",
       %{socket: socket, alice: alice} do
    account!(alice, "alice-1@x.com", [@cal_read])

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{connections: [row]}

    assert Enum.sort(Map.keys(row)) ==
             Enum.sort([
               :account_id,
               :email,
               :connector,
               :label,
               :access,
               :is_default,
               :shows_default,
               :only_grant
             ])

    refute Map.has_key?(row, :refresh_token)
    refute Map.has_key?(row, :access_token)
    refute Map.has_key?(row, :scope)
  end

  test "access is a string reflecting the granted scope", %{socket: socket, alice: alice} do
    account!(alice, "writer@x.com", [@cal_write])
    account!(alice, "reader@x.com", [@cal_read])

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{connections: rows}

    writer_row = Enum.find(rows, &(&1.email == "writer@x.com"))
    reader_row = Enum.find(rows, &(&1.email == "reader@x.com"))

    assert is_binary(writer_row.access)
    assert writer_row.access == "write"
    assert is_binary(reader_row.access)
    assert reader_row.access == "read"
  end

  test "connector is a string", %{socket: socket, alice: alice} do
    account!(alice, "alice-1@x.com", [@cal_read])

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{connections: [row]}
    assert is_binary(row.connector)
  end

  test "shows_default flips true only when two accounts share the connector",
       %{socket: socket, alice: alice} do
    account!(alice, "alice-1@x.com", [@cal_read])

    {:ok, _reply, _socket1} = join!(socket, alice)
    assert_push "state", %{connections: [row]}
    assert row.shows_default == false

    account!(alice, "alice-2@x.com", [@cal_read])

    {:ok, _reply, _socket2} = join!(socket, alice)
    assert_push "state", %{connections: rows}
    assert length(rows) == 2
    assert Enum.all?(rows, & &1.shows_default)
  end

  test "shows_default stays false when the second account has a different connector",
       %{socket: socket, alice: alice} do
    account!(alice, "cal@x.com", [@cal_read])
    account!(alice, "gmail@x.com", [@gmail_read])

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{connections: rows}
    assert length(rows) == 2
    refute Enum.any?(rows, & &1.shows_default)
  end

  test "only_grant is true only when the account holds exactly one grant",
       %{socket: socket, alice: alice} do
    account!(alice, "single@x.com", [@cal_read])
    account!(alice, "double@x.com", [@cal_read, @gmail_read])

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{connections: rows}

    single_row = Enum.find(rows, &(&1.email == "single@x.com"))
    double_rows = Enum.filter(rows, &(&1.email == "double@x.com"))

    assert single_row.only_grant == true
    assert length(double_rows) == 2
    assert Enum.all?(double_rows, &(&1.only_grant == false))
  end

  test "is_default reflects the column", %{socket: socket, alice: alice} do
    account!(alice, "default@x.com", [@cal_read], is_default: true)
    account!(alice, "other@x.com", [@gmail_read])

    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{connections: rows}

    default_row = Enum.find(rows, &(&1.email == "default@x.com"))
    other_row = Enum.find(rows, &(&1.email == "other@x.com"))

    assert default_row.is_default == true
    assert other_row.is_default == false
  end

  test "an empty account list pushes connections: []", %{socket: socket, alice: alice} do
    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", %{connections: []}
  end

  test "the state is the token's user, not the topic's", %{socket: socket, bob: bob} do
    account!(bob, "bob-1@x.com", [@cal_read])

    {:ok, _reply, _socket} = subscribe_and_join(socket, "panel:connectors:#{bob.id}", %{})

    assert_push "state", %{connections: rows}
    assert rows == []
    refute Enum.any?(rows, &(&1.email == "bob-1@x.com"))
  end

  # The join pushes one state; a successful write pushes another. Draining both
  # is not tidiness: leaving the second in flight puts the channel mid-query at
  # sandbox teardown and cascades "Database busy" through the whole file.
  defp drain_join!(socket, user) do
    {:ok, _reply, sock} = join!(socket, user)
    assert_push "state", _
    sock
  end

  describe "set_default" do
    test "on the user's own account persists and pushes a fresh state",
         %{socket: socket, alice: alice} do
      first = account!(alice, "first@x.com", [@cal_read])
      _second = account!(alice, "second@x.com", [@cal_read], is_default: true)

      sock = drain_join!(socket, alice)

      ref = push(sock, "set_default", %{"account_id" => first.id})
      assert_reply ref, :ok

      assert_push "state", %{connections: rows}
      first_row = Enum.find(rows, &(&1.email == "first@x.com"))
      second_row = Enum.find(rows, &(&1.email == "second@x.com"))
      assert first_row.is_default == true
      assert second_row.is_default == false
    end

    test "exactly ONE state follows a successful set_default",
         %{socket: socket, alice: alice} do
      first = account!(alice, "first@x.com", [@cal_read])
      _second = account!(alice, "second@x.com", [@cal_read], is_default: true)

      sock = drain_join!(socket, alice)

      ref = push(sock, "set_default", %{"account_id" => first.id})
      assert_reply ref, :ok

      assert_push "state", _
      refute_push "state", _, 200
    end

    test "on ANOTHER user's account is bad_request and changes nothing",
         %{socket: socket, alice: alice, bob: bob} do
      bobs = account!(bob, "bobs@x.com", [@cal_read], is_default: false)

      sock = drain_join!(socket, alice)

      ref = push(sock, "set_default", %{"account_id" => bobs.id})
      assert_reply ref, :error, %{reason: "bad_request"}

      refute_push "state", _, 200
      assert Repo.get(Account, bobs.id).is_default == false
    end

    test "with a non-integer account_id, or a missing key, is bad_request and the channel survives",
         %{socket: socket, alice: alice} do
      valid = account!(alice, "valid@x.com", [@cal_read])

      sock = drain_join!(socket, alice)

      ref = push(sock, "set_default", %{"account_id" => "3"})
      assert_reply ref, :error, %{reason: "bad_request"}

      ref = push(sock, "set_default", %{"account_id" => nil})
      assert_reply ref, :error, %{reason: "bad_request"}

      ref = push(sock, "set_default", %{})
      assert_reply ref, :error, %{reason: "bad_request"}

      # STANDING RULE: in Elixir, a "wrong type is rejected" test must use a
      # value that CROSS-TYPE-EQUALS a real one, or it proves nothing — a
      # string, nil, or unrelated number only tests the Enum.find MISS, not
      # the is_integer/1 guard. `3 == 3.0` is true, so without the guard,
      # Enum.find(&(&1.id == id)) matches a float id via `==` and silently
      # sets that account default. (Same trick bit the Voice Lock phase's
      # "non-integer id is rejected" test, which used "1" — never `==` an
      # integer — until it was rewritten to `fact.id * 1.0`.)
      ref = push(sock, "set_default", %{"account_id" => valid.id * 1.0})
      assert_reply ref, :error, %{reason: "bad_request"}
      refute Repo.get(Account, valid.id).is_default

      ref = push(sock, "set_default", %{"account_id" => valid.id})
      assert_reply ref, :ok
      assert_push "state", _
    end
  end

  describe "disconnect" do
    test "on a SOLE grant deletes the account and pushes a state without it",
         %{socket: socket, alice: alice} do
      account = account!(alice, "sole@x.com", [@cal_read])

      sock = drain_join!(socket, alice)

      ref = push(sock, "disconnect", %{"account_id" => account.id, "connector" => "calendar"})
      assert_reply ref, :ok

      assert_push "state", %{connections: []}
      assert Repo.get(Account, account.id) == nil
    end

    test "on a MULTI-grant account replies needs_web and deletes nothing",
         %{socket: socket, alice: alice} do
      account = account!(alice, "multi@x.com", [@cal_read, @gmail_read])
      original_scope = account.scope

      sock = drain_join!(socket, alice)

      ref = push(sock, "disconnect", %{"account_id" => account.id, "connector" => "calendar"})
      assert_reply ref, :error, %{reason: "needs_web"}

      refute_push "state", _, 200
      persisted = Repo.get(Account, account.id)
      assert persisted
      assert persisted.scope == original_scope
    end

    test "a stale client that sends only_grant cannot buy a delete",
         %{socket: socket, alice: alice} do
      account = account!(alice, "multi@x.com", [@cal_read, @gmail_read])

      sock = drain_join!(socket, alice)

      ref =
        push(sock, "disconnect", %{
          "account_id" => account.id,
          "connector" => "calendar",
          "only_grant" => true
        })

      assert_reply ref, :error, %{reason: "needs_web"}

      refute_push "state", _, 200
      assert Repo.get(Account, account.id)
    end

    test "for a connector the account does not hold at all replies needs_web and deletes nothing",
         %{socket: socket, alice: alice} do
      account = account!(alice, "cal-only@x.com", [@cal_read])

      sock = drain_join!(socket, alice)

      ref = push(sock, "disconnect", %{"account_id" => account.id, "connector" => "gmail"})
      assert_reply ref, :error, %{reason: "needs_web"}

      refute_push "state", _, 200
      assert Repo.get(Account, account.id)
    end

    test "an unknown connector string is bad_request and the channel survives",
         %{socket: socket, alice: alice} do
      account = account!(alice, "sole@x.com", [@cal_read])

      sock = drain_join!(socket, alice)

      for bad_connector <- ["drive", "Calendar", "elixir", 123] do
        ref =
          push(sock, "disconnect", %{"account_id" => account.id, "connector" => bad_connector})

        assert_reply ref, :error, %{reason: "bad_request"}
      end

      ref = push(sock, "disconnect", %{"account_id" => account.id})
      assert_reply ref, :error, %{reason: "bad_request"}

      assert Repo.get(Account, account.id)

      ref = push(sock, "disconnect", %{"account_id" => account.id, "connector" => "calendar"})
      assert_reply ref, :ok
      assert_push "state", _
    end

    # "drive"/"elixir" have no matching atom in the VM at all, so a
    # String.to_existing_atom/1 implementation would raise and crash the
    # channel on those — a failure, but the WRONG one (an unrelated process
    # exit, not a verdict on the allowlist). "email" and "scope" ARE already
    # existing atoms (used elsewhere in this module and its neighbours) but
    # are not connectors, so this is the case that actually distinguishes "is
    # a registry member" from "is merely a pre-existing atom" — and it fails
    # cleanly (a reply mismatch), not via a crash.
    test "a string that is an existing atom but not a connector is bad_request",
         %{socket: socket, alice: alice} do
      account = account!(alice, "sole@x.com", [@cal_read])

      sock = drain_join!(socket, alice)

      for not_a_connector <- ["email", "scope"] do
        ref =
          push(sock, "disconnect", %{"account_id" => account.id, "connector" => not_a_connector})

        assert_reply ref, :error, %{reason: "bad_request"}
      end

      assert Repo.get(Account, account.id)

      ref = push(sock, "disconnect", %{"account_id" => account.id, "connector" => "calendar"})
      assert_reply ref, :ok
      assert_push "state", _
    end

    test "on ANOTHER user's sole-grant account is bad_request",
         %{socket: socket, alice: alice, bob: bob} do
      bobs = account!(bob, "bobs@x.com", [@cal_read])

      sock = drain_join!(socket, alice)

      ref = push(sock, "disconnect", %{"account_id" => bobs.id, "connector" => "calendar"})
      assert_reply ref, :error, %{reason: "bad_request"}

      assert Repo.get(Account, bobs.id)
    end
  end

  test "an unknown event is bad_request and the channel survives", %{socket: socket, alice: alice} do
    account = account!(alice, "sole@x.com", [@cal_read])

    sock = drain_join!(socket, alice)

    ref = push(sock, "not_a_real_event", %{})
    assert_reply ref, :error, %{reason: "bad_request"}

    ref = push(sock, "disconnect", %{"account_id" => account.id, "connector" => "calendar"})
    assert_reply ref, :ok
    assert_push "state", _
  end

  # The socket is authenticated as Alice (the setup block's token), but this
  # joins BOB's topic suffix deliberately — mirroring the read-only "the state
  # is the token's user, not the topic's" test above, but for a WRITE. Every
  # other test in this file joins a user's own topic, which is exactly the
  # shape that let a topic-suffix mutant through on the sibling Memory
  # channel: own_account/2 must resolve against socket.assigns.user_id (the
  # token), never socket.topic (client-supplied), or this would let alice's
  # write succeed by looking up BOB's accounts instead of her own.
  test "a write resolves against the token's user, not the topic's suffix",
       %{socket: socket, alice: alice, bob: bob} do
    alices_account = account!(alice, "alices@x.com", [@cal_read])
    _bobs_account = account!(bob, "bobs@x.com", [@cal_read], is_default: true)

    {:ok, _reply, sock} = subscribe_and_join(socket, "panel:connectors:#{bob.id}", %{})
    assert_push "state", _

    ref = push(sock, "set_default", %{"account_id" => alices_account.id})
    assert_reply ref, :ok

    assert_push "state", %{connections: rows}
    assert [%{email: "alices@x.com", is_default: true}] = rows
    assert Repo.get(Account, alices_account.id).is_default == true
  end
end
