defmodule App.Google.CalendarTest do
  use App.DataCase, async: false

  alias App.Google.{Account, Calendar}
  alias App.Users.User

  # A persisted account with a fresh access token, so list_events doesn't try to refresh.
  defp account do
    {:ok, acc} =
      %Account{}
      |> Account.changeset(%{
        user_id: Process.get(:test_user_id),
        email: "a@x.com",
        label: "a@x.com",
        refresh_token: "rt",
        access_token: "at",
        access_token_expires_at:
          DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    acc
  end

  setup do
    {:ok, user} =
      %User{} |> User.changeset(%{email: "alice@x.com", name: "Alice"}) |> Repo.insert()

    Process.put(:test_user_id, user.id)
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, CalStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)
    :ok
  end

  defp opts, do: [time_min: "2026-06-18T00:00:00Z", time_max: "2026-06-19T00:00:00Z"]

  test "normalizes a timed event and an all-day event, tagging the account label" do
    Req.Test.stub(CalStub, fn conn ->
      Req.Test.json(conn, %{
        "items" => [
          %{
            "summary" => "Standup",
            "location" => "Zoom",
            "start" => %{"dateTime" => "2026-06-18T14:00:00Z"},
            "end" => %{"dateTime" => "2026-06-18T14:15:00Z"}
          },
          %{
            "summary" => "Holiday",
            "start" => %{"date" => "2026-06-18"},
            "end" => %{"date" => "2026-06-19"}
          }
        ]
      })
    end)

    assert {:ok, [timed, allday]} = Calendar.list_events(account(), opts())

    assert timed == %{
             summary: "Standup",
             start: "2026-06-18T14:00:00Z",
             end: "2026-06-18T14:15:00Z",
             location: "Zoom",
             all_day?: false,
             account: "a@x.com"
           }

    assert allday.summary == "Holiday"
    assert allday.all_day? == true
    assert allday.start == "2026-06-18"
    assert allday.account == "a@x.com"
  end

  test "missing summary falls back to a placeholder" do
    Req.Test.stub(CalStub, fn conn ->
      Req.Test.json(conn, %{
        "items" => [%{"start" => %{"date" => "2026-06-18"}, "end" => %{"date" => "2026-06-19"}}]
      })
    end)

    assert {:ok, [ev]} = Calendar.list_events(account(), opts())
    assert ev.summary == "(no title)"
  end

  test "an API error is returned, not raised" do
    Req.Test.stub(CalStub, fn conn -> Plug.Conn.send_resp(conn, 503, "nope") end)
    assert {:error, {:http, 503}} = Calendar.list_events(account(), opts())
  end

  test "retries a transient pre-send transport error, then succeeds (cold-pool recovery wiring)" do
    # The prod bug is a cold Finch pool returning :pool_not_available to the racing fan-out
    # requests; that error can't be produced through the Req.Test plug (it bypasses Finch's pool),
    # so we exercise the SAME retry wiring (App.Http.Retry.opts/0) with a :closed transport error,
    # which our predicate also treats as request-never-executed.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(CalStub, fn conn ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> Req.Test.transport_error(conn, :closed)
        _ -> Req.Test.json(conn, %{"items" => []})
      end
    end)

    assert {:ok, []} = Calendar.list_events(account(), opts())
    assert Agent.get(counter, & &1) == 2, "expected exactly one retry after the transport error"
  end

  test "does NOT retry a server-side 5xx (could double-execute a non-idempotent write)" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(CalStub, fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.send_resp(conn, 503, "nope")
    end)

    assert {:error, {:http, 503}} = Calendar.list_events(account(), opts())
    assert Agent.get(counter, & &1) == 1, "a 5xx reached the server — must not retry"
  end

  test "a 200 with no items returns an empty list" do
    Req.Test.stub(CalStub, fn conn -> Req.Test.json(conn, %{}) end)
    assert {:ok, []} = Calendar.list_events(account(), opts())
  end

  test "propagates needs_reconnect when the token refresh fails" do
    # account with an already-expired access token so valid_access_token attempts a refresh
    {:ok, acc} =
      %Account{}
      |> Account.changeset(%{
        user_id: Process.get(:test_user_id),
        email: "a@x.com",
        label: "a@x.com",
        refresh_token: "rt",
        access_token: "stale",
        access_token_expires_at: ~U[2000-01-01 00:00:00Z]
      })
      |> Repo.insert()

    System.put_env("GOOGLE_CLIENT_ID", "id")
    System.put_env("GOOGLE_CLIENT_SECRET", "secret")

    on_exit(fn ->
      System.delete_env("GOOGLE_CLIENT_ID")
      System.delete_env("GOOGLE_CLIENT_SECRET")
    end)

    # the shared CalStub (set in setup) will receive the token-refresh POST — return invalid_grant
    Req.Test.stub(CalStub, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
    end)

    assert {:error, :needs_reconnect} = Calendar.list_events(acc, opts())
  end

  test "create_event posts a timed event body and normalizes the result" do
    test_pid = self()

    Req.Test.stub(CalStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:posted, Jason.decode!(raw)})

      Req.Test.json(conn, %{
        "summary" => "Lunch",
        "start" => %{"dateTime" => "2026-06-20T12:00:00Z"},
        "end" => %{"dateTime" => "2026-06-20T13:00:00Z"},
        "htmlLink" => "https://cal/abc"
      })
    end)

    attrs = %{
      summary: "Lunch",
      start: "2026-06-20T12:00:00Z",
      end: "2026-06-20T13:00:00Z",
      all_day?: false,
      location: "Cafe"
    }

    assert {:ok, created} = Calendar.create_event(account(), attrs)

    assert created.summary == "Lunch"
    assert created.start == "2026-06-20T12:00:00Z"
    assert created.account == "a@x.com"
    assert created.html_link == "https://cal/abc"

    assert_received {:posted, body}
    assert body["start"]["dateTime"] == "2026-06-20T12:00:00Z"
    assert body["location"] == "Cafe"
  end

  test "create_event posts an all-day event body with date fields" do
    test_pid = self()

    Req.Test.stub(CalStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:posted, Jason.decode!(raw)})

      Req.Test.json(conn, %{
        "summary" => "Trip",
        "start" => %{"date" => "2026-06-20"},
        "end" => %{"date" => "2026-06-21"},
        "htmlLink" => "https://cal/t"
      })
    end)

    attrs = %{
      summary: "Trip",
      start: "2026-06-20",
      end: "2026-06-21",
      all_day?: true,
      location: nil
    }

    assert {:ok, created} = Calendar.create_event(account(), attrs)
    assert created.start == "2026-06-20"

    assert_received {:posted, body}
    assert body["start"]["date"] == "2026-06-20"
    refute Map.has_key?(body, "location")
  end

  test "create_event maps a 403 to needs_write_access" do
    Req.Test.stub(CalStub, fn conn -> Plug.Conn.send_resp(conn, 403, "insufficient") end)

    attrs = %{
      summary: "X",
      start: "2026-06-20T12:00:00Z",
      end: "2026-06-20T13:00:00Z",
      all_day?: false,
      location: nil
    }

    assert {:error, :needs_write_access} = Calendar.create_event(account(), attrs)
  end
end
