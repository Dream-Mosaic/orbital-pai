defmodule AppWeb.UserAuthTest do
  use AppWeb.ConnCase, async: true

  alias AppWeb.UserAuth
  alias App.Users
  alias App.Repo

  setup %{conn: conn} do
    Application.put_env(:app, :allowed_users, [%{email: "alice@x.com", name: "Alice"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    conn = conn |> Phoenix.ConnTest.init_test_session(%{})
    {:ok, conn: conn}
  end

  test "log_in_user stores the id and fetch_current_user assigns the user", %{conn: conn} do
    {:ok, user} = Users.upsert_allowed("alice@x.com")

    conn = UserAuth.log_in_user(conn, user)
    assert get_session(conn, :user_id) == user.id

    conn = conn |> fetch_flash() |> UserAuth.fetch_current_user([])
    assert conn.assigns.current_user.id == user.id
  end

  test "require_user redirects to /login when not signed in", %{conn: conn} do
    conn = conn |> fetch_flash() |> assign(:current_user, nil) |> UserAuth.require_user([])
    assert redirected_to(conn) == "/login"
    assert conn.halted
  end

  test "require_user passes through when signed in", %{conn: conn} do
    {:ok, user} = Users.upsert_allowed("alice@x.com")
    conn = conn |> assign(:current_user, user) |> UserAuth.require_user([])
    refute conn.halted
  end

  test "socket token round-trips the user id" do
    token = UserAuth.socket_token(123)
    assert {:ok, 123} = UserAuth.verify_socket_token(token)
    assert :error = UserAuth.verify_socket_token("garbage")
  end

  test "fetch_current_user drops a user whose email is no longer allowlisted", %{conn: conn} do
    {:ok, user} = Users.upsert_allowed("alice@x.com")
    # email removed from the allowlist after login
    Application.put_env(:app, :allowed_users, [])

    conn =
      conn
      |> Plug.Conn.put_session(:user_id, user.id)
      |> UserAuth.fetch_current_user([])

    assert conn.assigns.current_user == nil
  end

  test "authenticate_socket returns the user for a valid token + allowlisted user", %{conn: _conn} do
    {:ok, user} = Users.upsert_allowed("alice@x.com")
    token = UserAuth.socket_token(user.id)
    assert %App.Users.User{id: id} = UserAuth.authenticate_socket(token)
    assert id == user.id
  end

  test "authenticate_socket returns nil when the user row is gone", %{conn: _conn} do
    {:ok, user} = Users.upsert_allowed("alice@x.com")
    token = UserAuth.socket_token(user.id)
    Repo.delete!(user)
    assert UserAuth.authenticate_socket(token) == nil
  end

  test "on_mount(:default) halts with a redirect when the session has no valid user" do
    socket = %Phoenix.LiveView.Socket{}
    assert {:halt, _} = UserAuth.on_mount(:default, %{}, %{}, socket)
  end
end
