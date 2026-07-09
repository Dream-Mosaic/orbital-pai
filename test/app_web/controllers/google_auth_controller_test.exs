defmodule AppWeb.GoogleAuthControllerTest do
  use AppWeb.ConnCase, async: false

  alias App.Google.{Account, Accounts}
  alias App.Repo

  setup :register_and_log_in_user

  setup do
    System.put_env("GOOGLE_CLIENT_ID", "test-client-id")
    System.put_env("GOOGLE_CLIENT_SECRET", "test-secret")

    on_exit(fn ->
      System.delete_env("GOOGLE_CLIENT_ID")
      System.delete_env("GOOGLE_CLIENT_SECRET")
      Application.delete_env(:app, :google_req_opts)
    end)

    :ok
  end

  test "connect redirects to Google and stores a state in the session", %{conn: conn} do
    conn = get(conn, ~p"/auth/google/connect")

    assert redirected_to(conn, 302) =~ "https://accounts.google.com/o/oauth2/v2/auth"
    assert get_session(conn, :google_oauth_state) != nil
  end

  test "callback with mismatched state fails without touching the DB", %{conn: conn, user: user} do
    conn =
      conn
      |> init_test_session(%{google_oauth_state: "expected"})
      |> get(~p"/auth/google/callback?state=WRONG&code=abc")

    assert redirected_to(conn) == ~p"/"
    assert Accounts.list(user.id) == []
  end

  test "callback happy path exchanges the code and upserts the account", %{conn: conn} do
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, CbStub})

    id_token =
      "h." <>
        Base.url_encode64(Jason.encode!(%{"email" => "alice@example.com"}),
          padding: false
        ) <> ".sig"

    Req.Test.stub(CbStub, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "at-1",
        "refresh_token" => "rt-1",
        "expires_in" => 3599,
        "id_token" => id_token
      })
    end)

    conn =
      conn
      |> init_test_session(%{google_oauth_state: "s1"})
      |> get(~p"/auth/google/callback?state=s1&code=auth-code")

    assert redirected_to(conn) == ~p"/"
    assert Accounts.get_by_email("alice@example.com")
    assert get_session(conn, :google_oauth_state) == nil
  end

  test "callback with an error param redirects without creating an account", %{
    conn: conn,
    user: user
  } do
    conn =
      conn
      |> init_test_session(%{google_oauth_state: "s1"})
      |> get(~p"/auth/google/callback?state=s1&error=access_denied")

    assert redirected_to(conn) == ~p"/"
    assert Accounts.list(user.id) == []
  end

  test "callback redirects gracefully when the token exchange fails", %{conn: conn, user: user} do
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, CbFailStub})

    Req.Test.stub(CbFailStub, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
    end)

    conn =
      conn
      |> init_test_session(%{google_oauth_state: "s1"})
      |> get(~p"/auth/google/callback?state=s1&code=bad-code")

    assert redirected_to(conn) == ~p"/"
    assert Accounts.list(user.id) == []
  end

  test "connect without configured credentials flashes and redirects home", %{conn: conn} do
    System.delete_env("GOOGLE_CLIENT_ID")
    System.delete_env("GOOGLE_CLIENT_SECRET")
    conn = get(conn, ~p"/auth/google/connect")
    assert redirected_to(conn) == ~p"/"
  end

  test "bare connect requests full calendar (write) scopes", %{conn: conn} do
    conn = get(conn, ~p"/auth/google/connect")
    loc = redirected_to(conn, 302)
    assert loc =~ "accounts.google.com"
    assert loc =~ URI.encode_www_form("calendar.events")
  end

  test "connect with calendar=read requests only the readonly scope", %{conn: conn} do
    conn = get(conn, ~p"/auth/google/connect?calendar=read")
    loc = redirected_to(conn, 302)
    assert loc =~ URI.encode_www_form("calendar.readonly")
    refute loc =~ URI.encode_www_form("calendar.events")
  end

  test "reducing an existing account's access revokes before reconnecting", %{
    conn: conn,
    user: user
  } do
    {:ok, acc} =
      %Account{}
      |> Account.changeset(%{
        user_id: user.id,
        email: "a@x.com",
        label: "a@x.com",
        refresh_token: "rt-live",
        scope: "https://www.googleapis.com/auth/calendar.events openid email"
      })
      |> Repo.insert()

    test_pid = self()
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, RevokeOnReduceStub})

    Req.Test.stub(RevokeOnReduceStub, fn c ->
      send(test_pid, :revoked)
      Req.Test.json(c, %{})
    end)

    conn = get(conn, ~p"/auth/google/connect?account=#{acc.id}&calendar=read")
    assert redirected_to(conn, 302) =~ "accounts.google.com"
    assert_received :revoked
  end

  test "a failed revoke aborts the change with a flash instead of proceeding to Google", %{
    conn: conn,
    user: user
  } do
    {:ok, acc} =
      %Account{}
      |> Account.changeset(%{
        user_id: user.id,
        email: "d@x.com",
        label: "d@x.com",
        refresh_token: "rt-live",
        scope: "https://www.googleapis.com/auth/calendar.events openid email"
      })
      |> Repo.insert()

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, RevokeFailStub})

    Req.Test.stub(RevokeFailStub, fn c ->
      c |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad"})
    end)

    conn = get(conn, ~p"/auth/google/connect?account=#{acc.id}&calendar=read")
    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "revoke"
  end

  test "setting an existing account to none requests only openid/email and revokes", %{
    conn: conn,
    user: user
  } do
    {:ok, acc} =
      %Account{}
      |> Account.changeset(%{
        user_id: user.id,
        email: "c@x.com",
        label: "c@x.com",
        refresh_token: "rt-live",
        scope: "https://www.googleapis.com/auth/calendar.events openid email"
      })
      |> Repo.insert()

    test_pid = self()
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, NoneStub})

    Req.Test.stub(NoneStub, fn c ->
      send(test_pid, :revoked)
      Req.Test.json(c, %{})
    end)

    conn = get(conn, ~p"/auth/google/connect?account=#{acc.id}")
    loc = redirected_to(conn, 302)
    refute loc =~ URI.encode_www_form("calendar.readonly")
    refute loc =~ URI.encode_www_form("calendar.events")
    assert loc =~ "scope=openid"
    assert_received :revoked
  end

  test "widening an existing account does not revoke", %{conn: conn, user: user} do
    {:ok, acc} =
      %Account{}
      |> Account.changeset(%{
        user_id: user.id,
        email: "b@x.com",
        label: "b@x.com",
        refresh_token: "rt-live",
        scope: "https://www.googleapis.com/auth/calendar.readonly openid email"
      })
      |> Repo.insert()

    test_pid = self()
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, NoRevokeStub})

    Req.Test.stub(NoRevokeStub, fn c ->
      send(test_pid, :revoked)
      Req.Test.json(c, %{})
    end)

    conn = get(conn, ~p"/auth/google/connect?account=#{acc.id}&calendar=write")
    assert redirected_to(conn, 302) =~ "accounts.google.com"
    refute_received :revoked
  end
end
