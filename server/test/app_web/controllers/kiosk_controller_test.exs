defmodule AppWeb.KioskControllerTest do
  use AppWeb.ConnCase, async: false

  alias App.Repo
  alias App.Users
  alias App.Users.User

  setup %{conn: conn} do
    Application.put_env(:app, :allowed_users, [
      %{email: "alice@x.com", name: "Alice"},
      %{email: "bob@x.com", name: "Bob"}
    ])

    on_exit(fn ->
      Application.delete_env(:app, :allowed_users)
      Application.delete_env(:app, :kiosk_user_switch)
    end)

    {:ok, alice} = Users.upsert_allowed("alice@x.com")
    {:ok, bob} = Users.upsert_allowed("bob@x.com")

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, alice.id)

    %{conn: conn, alice: alice, bob: bob}
  end

  describe "POST /kiosk/switch_user" do
    test "gate off + authed + valid allowlisted target -> 403, session unchanged", %{
      conn: conn,
      alice: alice,
      bob: bob
    } do
      Application.put_env(:app, :kiosk_user_switch, false)

      conn = post(conn, ~p"/kiosk/switch_user", %{"user_id" => to_string(bob.id)})

      assert conn.status == 403
      assert get_session(conn, :user_id) == alice.id
    end

    test "gate on + authed + allowlisted target -> session becomes target + redirect /?kiosk=1",
         %{conn: conn, bob: bob} do
      Application.put_env(:app, :kiosk_user_switch, true)

      conn = post(conn, ~p"/kiosk/switch_user", %{"user_id" => to_string(bob.id)})

      assert redirected_to(conn) == "/?kiosk=1"
      assert get_session(conn, :user_id) == bob.id
    end

    test "gate on + a target user that exists but is NOT allowlisted -> 403, session unchanged",
         %{conn: conn, alice: alice} do
      Application.put_env(:app, :kiosk_user_switch, true)

      {:ok, eve} =
        %User{}
        |> User.changeset(%{email: "eve@evil.com", name: "Eve"})
        |> Repo.insert()

      conn = post(conn, ~p"/kiosk/switch_user", %{"user_id" => to_string(eve.id)})

      assert conn.status == 403
      assert get_session(conn, :user_id) == alice.id
    end

    test "gate on + garbage user_id ('abc') -> 403, session unchanged, no crash", %{
      conn: conn,
      alice: alice
    } do
      Application.put_env(:app, :kiosk_user_switch, true)

      conn = post(conn, ~p"/kiosk/switch_user", %{"user_id" => "abc"})

      assert conn.status == 403
      assert get_session(conn, :user_id) == alice.id
    end

    test "gate on + a huge non-existent numeric user_id -> 403, session unchanged", %{
      conn: conn,
      alice: alice
    } do
      Application.put_env(:app, :kiosk_user_switch, true)

      conn = post(conn, ~p"/kiosk/switch_user", %{"user_id" => "999999999"})

      assert conn.status == 403
      assert get_session(conn, :user_id) == alice.id
    end

    test "gate on + malformed user_id (partial-parse/float/empty/whitespace) -> 403, no switch",
         %{
           conn: conn,
           alice: alice
         } do
      Application.put_env(:app, :kiosk_user_switch, true)

      # Integer.parse leaks a partial number ({1, ";drop"}) — to_int/1 must reject anything with a
      # trailing remainder, so none of these can resolve to a real user id.
      for bad <- ["1;drop", "1.5", "", " 5", "0x1F"] do
        c = post(conn, ~p"/kiosk/switch_user", %{"user_id" => bad})
        assert c.status == 403, "expected 403 for user_id=#{inspect(bad)}"
        assert get_session(c, :user_id) == alice.id
      end
    end

    test "gate on + missing user_id param entirely -> 403, session unchanged", %{
      conn: conn,
      alice: alice
    } do
      Application.put_env(:app, :kiosk_user_switch, true)

      conn = post(conn, ~p"/kiosk/switch_user", %{})

      assert conn.status == 403
      assert get_session(conn, :user_id) == alice.id
    end

    test "gate on + a non-string/non-integer user_id shape (list) -> 403, no crash", %{
      conn: conn,
      alice: alice
    } do
      Application.put_env(:app, :kiosk_user_switch, true)

      conn = post(conn, ~p"/kiosk/switch_user", %{"user_id" => ["1", "2"]})

      assert conn.status == 403
      assert get_session(conn, :user_id) == alice.id
    end

    test "unauthenticated POST redirects to /login (router plug halts before the controller)" do
      Application.put_env(:app, :kiosk_user_switch, true)

      conn =
        Phoenix.ConnTest.build_conn()
        |> post(~p"/kiosk/switch_user", %{"user_id" => "1"})

      assert redirected_to(conn) == "/login"
    end
  end
end
