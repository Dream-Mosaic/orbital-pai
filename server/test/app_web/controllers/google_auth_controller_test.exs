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

  describe "returning to the native app" do
    test "connect?return=app records the app as the return target", %{conn: conn} do
      conn = get(conn, ~p"/auth/google/connect?return=app&calendar=read")

      assert redirected_to(conn, 302) =~ "accounts.google.com"
      assert get_session(conn, :google_oauth_return) == "app"
    end

    test "a bare connect still returns to the web", %{conn: conn} do
      conn = get(conn, ~p"/auth/google/connect")

      assert get_session(conn, :google_oauth_return) == "web"
    end

    # `return` is an allowlist of one, not a destination. If an arbitrary value were honored
    # this parameter would be an open redirect: anyone could hand our own user a link that
    # bounces them off our domain to somewhere else, carrying our flash and our session.
    test "an unrecognized return target is ignored rather than honored", %{conn: conn} do
      conn = get(conn, ~p"/auth/google/connect?return=https://evil.example.com/x")

      assert get_session(conn, :google_oauth_return) == "web"
      assert redirected_to(conn, 302) =~ "accounts.google.com"
    end

    test "a successful callback on an app flow deep-links back into the app", %{conn: conn} do
      stub_token_exchange("deep@example.com")

      conn =
        conn
        |> init_test_session(%{google_oauth_state: "s1", google_oauth_return: "app"})
        |> get(~p"/auth/google/callback?state=s1&code=auth-code")

      assert app_link(conn) == "orbital://connectors?status=ok"
      assert html_response(conn, 200) =~ "Connected"
      assert html_response(conn, 200) =~ "You can close this tab"
      assert Accounts.get_by_email("deep@example.com")
      assert get_session(conn, :google_oauth_return) == nil
    end

    test "a failed callback on an app flow deep-links back with an error status", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{google_oauth_state: "s1", google_oauth_return: "app"})
        |> get(~p"/auth/google/callback?state=s1&error=access_denied")

      assert app_link(conn) == "orbital://connectors?status=error"
      assert html_response(conn, 200) =~ "Didn&#39;t complete"
    end

    test "a pre-hop failure on an app flow renders the page with an error link", %{conn: conn} do
      System.delete_env("GOOGLE_CLIENT_ID")
      System.delete_env("GOOGLE_CLIENT_SECRET")
      conn = get(conn, ~p"/auth/google/connect?return=app&calendar=read")

      assert app_link(conn) == "orbital://connectors?status=error"
      assert html_response(conn, 200) =~ "Didn&#39;t complete"
    end

    # The web surface predates all of this and must be untouched by it: a flow with no recorded
    # return target lands home with a flash, exactly as before.
    test "a callback with no recorded return target finishes on the web", %{conn: conn} do
      stub_token_exchange("web@example.com")

      conn =
        conn
        |> init_test_session(%{google_oauth_state: "s1"})
        |> get(~p"/auth/google/callback?state=s1&code=auth-code")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "web@example.com"
    end

    # Failing BEFORE the hop to Google is the case most likely to strand someone: the browser
    # never leaves our domain, so without this the app-launched tab just sits on the web UI.
    test "a failed revoke on an app flow returns to the app instead of stranding the browser",
         %{conn: conn, user: user} do
      {:ok, acc} =
        %Account{}
        |> Account.changeset(%{
          user_id: user.id,
          email: "strand@x.com",
          label: "strand@x.com",
          refresh_token: "rt-live",
          scope: "https://www.googleapis.com/auth/calendar.events openid email"
        })
        |> Repo.insert()

      Application.put_env(:app, :google_req_opts, plug: {Req.Test, AppRevokeFailStub})

      Req.Test.stub(AppRevokeFailStub, fn c ->
        c |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad"})
      end)

      conn =
        get(conn, ~p"/auth/google/connect?return=app&account=#{acc.id}&calendar=read")

      assert app_link(conn) == "orbital://connectors?status=error"
      assert html_response(conn, 200) =~ "Didn&#39;t complete"
    end

    test "missing credentials on an app flow returns to the app", %{conn: conn} do
      System.delete_env("GOOGLE_CLIENT_ID")

      conn = get(conn, ~p"/auth/google/connect?return=app&calendar=read")

      assert app_link(conn) == "orbital://connectors?status=error"
      assert html_response(conn, 200) =~ "Didn&#39;t complete"
    end
  end

  describe "resuming a signed-out request after sign-in" do
    setup do
      # The signed-out conn these tests need: the module-level
      # `register_and_log_in_user` has already put a user in the session on `conn`.
      %{anon: Phoenix.ConnTest.build_conn()}
    end

    test "a refused GET remembers what it was asking for", %{anon: anon} do
      path = "/auth/google/connect?return=app&calendar=read"
      conn = get(anon, path)

      assert redirected_to(conn) == "/login"
      assert get_session(conn, :user_return_to) == path
    end

    # Resuming a POST would replay a write the user never re-confirmed.
    test "a refused POST is not remembered", %{anon: anon} do
      conn = post(anon, ~p"/kiosk/switch_user", %{})

      assert redirected_to(conn) == "/login"
      assert get_session(conn, :user_return_to) == nil
    end
  end

  defp app_link(conn) do
    body = html_response(conn, 200)
    [link] = Regex.run(~r/orbital:\/\/[a-z]+\?[^"]+/, body)
    String.replace(link, "&amp;", "&")
  end

  defp stub_token_exchange(email) do
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, TokenStub})

    Req.Test.stub(TokenStub, fn c ->
      Req.Test.json(c, %{
        "access_token" => "at-1",
        "refresh_token" => "rt-1",
        "expires_in" => 3599,
        "id_token" => id_token(email)
      })
    end)
  end

  defp id_token(email),
    do:
      "h." <>
        Base.url_encode64(Jason.encode!(%{"email" => email}), padding: false) <> ".sig"
end
