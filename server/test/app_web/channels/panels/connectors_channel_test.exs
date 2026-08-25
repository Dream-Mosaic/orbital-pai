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
end
