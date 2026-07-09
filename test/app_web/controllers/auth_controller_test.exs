defmodule AppWeb.AuthControllerTest do
  use AppWeb.ConnCase, async: false

  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "alice@x.com", name: "Alice"}])
    System.put_env("GOOGLE_CLIENT_ID", "id")
    System.put_env("GOOGLE_CLIENT_SECRET", "secret")

    on_exit(fn ->
      Application.delete_env(:app, :allowed_users)
      System.delete_env("GOOGLE_CLIENT_ID")
      System.delete_env("GOOGLE_CLIENT_SECRET")
    end)

    :ok
  end

  test "GET /login renders a Sign in with Google link", %{conn: conn} do
    conn = get(conn, ~p"/login")
    assert html_response(conn, 200) =~ "Sign in with Google"
  end

  test "an unauthenticated request to / redirects to /login", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/login"
  end

  test "login redirects to Google's consent with openid+email and flow=login", %{conn: conn} do
    conn = get(conn, ~p"/auth/login")
    loc = redirected_to(conn)
    assert loc =~ "accounts.google.com"
    assert loc =~ "openid+email" or loc =~ "openid%20email"
    assert get_session(conn, :google_oauth_flow) == "login"
  end

  test "callback with a login flow + allowlisted email logs the user in", %{conn: conn} do
    id_token = unsigned_id_token("alice@x.com")
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, AuthStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)

    Req.Test.stub(AuthStub, fn c ->
      Req.Test.json(c, %{
        "access_token" => "at",
        "refresh_token" => "rt",
        "expires_in" => 3600,
        "id_token" => id_token,
        "scope" => "openid email"
      })
    end)

    conn =
      conn
      |> init_test_session(%{google_oauth_state: "s", google_oauth_flow: "login"})
      |> get(~p"/auth/google/callback", %{"state" => "s", "code" => "c"})

    assert redirected_to(conn) == "/"
    user = Users.get_by_email("alice@x.com")
    assert get_session(conn, :user_id) == user.id
  end

  test "callback login flow with a non-allowlisted email is denied", %{conn: conn} do
    id_token = unsigned_id_token("stranger@x.com")
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, AuthStub2})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)

    Req.Test.stub(AuthStub2, fn c ->
      Req.Test.json(c, %{
        "access_token" => "at",
        "refresh_token" => "rt",
        "expires_in" => 3600,
        "id_token" => id_token,
        "scope" => "openid email"
      })
    end)

    conn =
      conn
      |> init_test_session(%{google_oauth_state: "s", google_oauth_flow: "login"})
      |> get(~p"/auth/google/callback", %{"state" => "s", "code" => "c"})

    assert redirected_to(conn) == "/login"
    assert is_nil(get_session(conn, :user_id))
    assert is_nil(Users.get_by_email("stranger@x.com"))
  end

  defp unsigned_id_token(email) do
    payload = %{"email" => email} |> Jason.encode!() |> Base.url_encode64(padding: false)
    "header.#{payload}.sig"
  end
end
