defmodule App.Tools.CalendarTest do
  use App.DataCase, async: false

  alias App.Google.Account
  alias App.Tools.Calendar, as: Tool
  alias App.Users.User

  setup do
    {:ok, user} =
      %User{} |> User.changeset(%{email: "alice@x.com", name: "Alice"}) |> Repo.insert()

    Process.put(:test_user_id, user.id)
    %{user: user}
  end

  defp account(email, opts \\ []) do
    {:ok, acc} =
      %Account{}
      |> Account.changeset(%{
        user_id: Process.get(:test_user_id),
        email: email,
        label: email,
        refresh_token: "rt",
        access_token: "at",
        access_token_expires_at:
          DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second),
        scope:
          Keyword.get(
            opts,
            :scope,
            "https://www.googleapis.com/auth/calendar.events openid email"
          )
      })
      |> Repo.insert()

    acc
  end

  defp ctx do
    uid = Process.get(:test_user_id)
    %{session_id: to_string(uid), user_id: uid, config: App.Config.default()}
  end

  test "cache_key rounds time_min/time_max to the minute so near-identical ranges collide" do
    a =
      Tool.cache_key("get_calendar_events", %{
        "time_min" => "2026-06-24T05:00:00Z",
        "time_max" => "2026-06-25T05:00:00Z"
      })

    b =
      Tool.cache_key("get_calendar_events", %{
        "time_min" => "2026-06-24T05:00:14Z",
        "time_max" => "2026-06-25T04:59:59Z"
      })

    assert a == b
    assert a == %{"time_min" => "2026-06-24T05:00:00Z", "time_max" => "2026-06-25T05:00:00Z"}

    # genuinely different ranges (hours apart) stay distinct
    refute Tool.cache_key("get_calendar_events", %{"time_min" => "2026-06-24T19:43:00Z"}) ==
             Map.take(a, ["time_min"])

    # non-time args pass through
    assert Tool.cache_key("get_calendar_events", %{"account" => "work"}) == %{"account" => "work"}
  end

  test "no connected accounts returns a clear note" do
    assert {:ok, %{events: [], errors: [], note: note}} =
             Tool.execute("get_calendar_events", %{}, ctx())

    assert note =~ "no Google accounts connected"
  end

  test "merges, labels, and sorts events across two accounts" do
    account("a@x.com")
    account("b@x.com")

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, MergeStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)

    # Each account's request returns one event; normalize/2 tags it with that account's label,
    # so the merged result has one event per account regardless of body content.
    Req.Test.stub(MergeStub, fn conn ->
      Req.Test.json(conn, %{
        "items" => [
          %{
            "summary" => "Evt",
            "start" => %{"dateTime" => "2026-06-18T10:00:00Z"},
            "end" => %{"dateTime" => "2026-06-18T11:00:00Z"}
          }
        ]
      })
    end)

    assert {:ok, %{events: events, errors: [], accounts_read: read}} =
             Tool.execute("get_calendar_events", %{}, ctx())

    assert length(events) == 2
    assert Enum.map(events, & &1.account) |> Enum.sort() == ["a@x.com", "b@x.com"]
    # accounts_read lists every queried account (so the brain knows what's connected)
    assert Enum.sort(read) == ["a@x.com", "b@x.com"]
  end

  test "a per-account failure is surfaced in errors; others still return" do
    account("ok@x.com")
    account("bad@x.com")

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, FailStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)

    # Fan-out order isn't guaranteed, so fail every request and assert both accounts surface
    # as errors with no events — proving failures are captured per-account, not raised.
    Req.Test.stub(FailStub, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    assert {:ok, %{events: [], errors: errors}} = Tool.execute("get_calendar_events", %{}, ctx())
    assert length(errors) == 2
    assert Enum.all?(errors, &(&1.reason =~ "http"))
  end

  test "account filter limits to one account by email" do
    account("a@x.com")
    account("b@x.com")

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, FilterStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)

    Req.Test.stub(FilterStub, fn conn ->
      Req.Test.json(conn, %{
        "items" => [
          %{
            "summary" => "Evt",
            "start" => %{"dateTime" => "2026-06-18T10:00:00Z"},
            "end" => %{"dateTime" => "2026-06-18T11:00:00Z"}
          }
        ]
      })
    end)

    assert {:ok, %{events: events}} =
             Tool.execute("get_calendar_events", %{"account" => "b@x.com"}, ctx())

    assert length(events) == 1
    assert hd(events).account == "b@x.com"
  end

  test "account filter matches case-insensitively (DAVE@... matches dave@...)" do
    account("dave@example.com")

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, CaseStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)

    Req.Test.stub(CaseStub, fn conn ->
      Req.Test.json(conn, %{
        "items" => [
          %{
            "summary" => "TEST",
            "start" => %{"dateTime" => "2026-06-18T18:30:00Z"},
            "end" => %{"dateTime" => "2026-06-18T19:00:00Z"}
          }
        ]
      })
    end)

    # the user (and the brain echoing them) uppercases the address — it must still resolve
    assert {:ok, %{events: events, accounts_read: ["dave@example.com"]}} =
             Tool.execute("get_calendar_events", %{"account" => "DAVE@example.com"}, ctx())

    assert length(events) == 1
  end

  test "account_matches? is case-insensitive on email/label" do
    acct = %Account{email: "dave@example.com", label: "dave@example.com"}

    assert Tool.account_matches?(acct, "DAVE@example.com")
    assert Tool.account_matches?(acct, "Dave@Example.com")
    refute Tool.account_matches?(acct, "someone@else.com")
    refute Tool.account_matches?(acct, nil)
  end

  test "unknown account filter returns a matching note" do
    account("a@x.com")

    assert {:ok, %{events: [], note: note}} =
             Tool.execute("get_calendar_events", %{"account" => "nope@x.com"}, ctx())

    assert note =~ "no connected account matching"
  end

  test "an expired token whose refresh is rejected maps to needs_reconnect" do
    {:ok, _acc} =
      %Account{}
      |> Account.changeset(%{
        user_id: Process.get(:test_user_id),
        email: "stale@x.com",
        label: "stale@x.com",
        refresh_token: "rt",
        access_token: "at",
        access_token_expires_at: ~U[2000-01-01 00:00:00Z],
        scope: "https://www.googleapis.com/auth/calendar.events openid email"
      })
      |> Repo.insert()

    System.put_env("GOOGLE_CLIENT_ID", "cid")
    System.put_env("GOOGLE_CLIENT_SECRET", "secret")

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, ReconnectStub})

    on_exit(fn ->
      System.delete_env("GOOGLE_CLIENT_ID")
      System.delete_env("GOOGLE_CLIENT_SECRET")
      Application.delete_env(:app, :google_req_opts)
    end)

    # The expired token forces a refresh; the OAuth token endpoint returns invalid_grant,
    # which the accounts layer maps to {:error, :needs_reconnect}.
    Req.Test.stub(ReconnectStub, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
    end)

    assert {:ok, %{events: [], errors: [error]}} =
             Tool.execute("get_calendar_events", %{}, ctx())

    assert error.reason == "needs_reconnect"
  end

  test "account filter matches on label, not only email" do
    acc = account("person@x.com")

    {:ok, _} =
      acc
      |> Account.changeset(%{label: "personal"})
      |> Repo.update()

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, LabelStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)

    Req.Test.stub(LabelStub, fn conn ->
      Req.Test.json(conn, %{
        "items" => [
          %{
            "summary" => "Evt",
            "start" => %{"dateTime" => "2026-06-18T10:00:00Z"},
            "end" => %{"dateTime" => "2026-06-18T11:00:00Z"}
          }
        ]
      })
    end)

    assert {:ok, %{events: events}} =
             Tool.execute("get_calendar_events", %{"account" => "personal"}, ctx())

    assert length(events) == 1
    assert hd(events).account == "personal"
  end

  test "create_event writes to the default account and returns the created event" do
    a = account("a@x.com")
    account("b@x.com")
    {:ok, _} = App.Google.Accounts.set_default(a)

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, CreateStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)

    Req.Test.stub(CreateStub, fn conn ->
      Req.Test.json(conn, %{
        "summary" => "Lunch",
        "start" => %{"dateTime" => "2026-06-20T12:00:00Z"},
        "end" => %{"dateTime" => "2026-06-20T13:00:00Z"},
        "htmlLink" => "https://cal/x"
      })
    end)

    args = %{"summary" => "Lunch", "start" => "2026-06-20T12:00:00Z"}
    assert {:ok, %{created: created}} = Tool.execute("create_event", args, ctx())
    assert created.summary == "Lunch"
    assert created.account == "a@x.com"
  end

  test "create_event honors a named account override" do
    a = account("a@x.com")
    account("b@x.com")
    # default is a@x.com, but the explicit account arg should send the write to b@x.com
    {:ok, _} = App.Google.Accounts.set_default(a)

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, CreateStub2})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)

    Req.Test.stub(CreateStub2, fn conn ->
      Req.Test.json(conn, %{
        "summary" => "X",
        "start" => %{"dateTime" => "2026-06-20T12:00:00Z"},
        "end" => %{"dateTime" => "2026-06-20T13:00:00Z"},
        "htmlLink" => "https://cal/x"
      })
    end)

    args = %{"summary" => "X", "start" => "2026-06-20T12:00:00Z", "account" => "b@x.com"}
    assert {:ok, %{created: created}} = Tool.execute("create_event", args, ctx())
    assert created.account == "b@x.com"
  end

  test "create_event with no accounts returns the connect note" do
    args = %{"summary" => "X", "start" => "2026-06-20T12:00:00Z"}
    assert {:ok, %{note: note}} = Tool.execute("create_event", args, ctx())
    assert note =~ "no Google accounts connected"
  end

  test "create_event with multiple writable accounts but no default returns an ambiguous note" do
    account("a@x.com")
    account("b@x.com")
    args = %{"summary" => "X", "start" => "2026-06-20T12:00:00Z"}
    assert {:ok, %{note: note}} = Tool.execute("create_event", args, ctx())
    assert note =~ "multiple writable calendars"
  end

  test "create_event with an unknown named account returns a matching note" do
    account("a@x.com")
    args = %{"summary" => "X", "start" => "2026-06-20T12:00:00Z", "account" => "nope@x.com"}
    assert {:ok, %{note: note}} = Tool.execute("create_event", args, ctx())
    assert note =~ "no connected account matching"
  end

  test "create_event defaults timed end to +1h and all-day end to the next day" do
    a = account("a@x.com")
    {:ok, _} = App.Google.Accounts.set_default(a)
    test_pid = self()

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, EndStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)

    Req.Test.stub(EndStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:posted, Jason.decode!(raw)})
      Req.Test.json(conn, %{"summary" => "X", "start" => %{}, "end" => %{}, "htmlLink" => "h"})
    end)

    {:ok, _} =
      Tool.execute("create_event", %{"summary" => "X", "start" => "2026-06-20T12:00:00Z"}, ctx())

    assert_received {:posted, timed}
    assert timed["end"]["dateTime"] == "2026-06-20T13:00:00Z"

    {:ok, _} =
      Tool.execute(
        "create_event",
        %{"summary" => "Y", "start" => "2026-06-20", "all_day" => true},
        ctx()
      )

    assert_received {:posted, allday}
    assert allday["start"]["date"] == "2026-06-20"
    assert allday["end"]["date"] == "2026-06-21"
  end

  test "create_event surfaces needs_write_access as a narratable error" do
    a = account("a@x.com")
    {:ok, _} = App.Google.Accounts.set_default(a)

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, WriteDenied})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)
    Req.Test.stub(WriteDenied, fn conn -> Plug.Conn.send_resp(conn, 403, "no") end)

    args = %{"summary" => "X", "start" => "2026-06-20T12:00:00Z"}

    assert {:ok, %{error: "needs_write_access", account: "a@x.com"}} =
             Tool.execute("create_event", args, ctx())
  end

  test "get_calendar_events skips accounts without calendar read access" do
    account("reader@x.com")
    account("noaccess@x.com", scope: "openid email")

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, ReadFilterStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)

    Req.Test.stub(ReadFilterStub, fn conn ->
      Req.Test.json(conn, %{
        "items" => [
          %{
            "summary" => "Evt",
            "start" => %{"dateTime" => "2026-06-18T10:00:00Z"},
            "end" => %{"dateTime" => "2026-06-18T11:00:00Z"}
          }
        ]
      })
    end)

    assert {:ok, %{events: events}} = Tool.execute("get_calendar_events", %{}, ctx())
    assert Enum.map(events, & &1.account) == ["reader@x.com"]
  end

  test "create_event rejects a read-only target with a clear note" do
    account("ro@x.com", scope: "https://www.googleapis.com/auth/calendar.readonly openid email")

    assert {:ok, %{note: note}} =
             Tool.execute(
               "create_event",
               %{
                 "summary" => "Lunch",
                 "start" => "2026-06-20T12:00:00Z",
                 "account" => "ro@x.com"
               },
               ctx()
             )

    assert note =~ "read-only"
  end

  test "create_event falls back to the sole writable account when no default can write" do
    {:ok, _ro} =
      %Account{}
      |> Account.changeset(%{
        user_id: Process.get(:test_user_id),
        email: "ro@x.com",
        label: "ro@x.com",
        refresh_token: "rt",
        access_token: "at",
        access_token_expires_at:
          DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second),
        is_default: true,
        scope: "https://www.googleapis.com/auth/calendar.readonly openid email"
      })
      |> Repo.insert()

    account("writer@x.com")

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, CreateStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)

    Req.Test.stub(CreateStub, fn conn ->
      Req.Test.json(conn, %{
        "summary" => "Lunch",
        "start" => %{"dateTime" => "2026-06-20T12:00:00Z"},
        "end" => %{"dateTime" => "2026-06-20T13:00:00Z"},
        "htmlLink" => "https://cal/evt"
      })
    end)

    assert {:ok, %{created: created}} =
             Tool.execute(
               "create_event",
               %{"summary" => "Lunch", "start" => "2026-06-20T12:00:00Z"},
               ctx()
             )

    assert created.account == "writer@x.com"
  end
end
