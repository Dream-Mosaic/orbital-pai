defmodule AppWeb.AuthControllerTest do
  use AppWeb.ConnCase, async: false

  alias App.Auth.Oidc

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "alice@x.com", name: "Alice"}])
    System.put_env("GOOGLE_CLIENT_ID", "id")
    System.put_env("GOOGLE_CLIENT_SECRET", "secret")

    Application.put_env(:app, :oidc_issuer, "https://auth.example.com/application/o/orbital/")
    Application.put_env(:app, :oidc_client_id, "cid")
    Application.put_env(:app, :oidc_client_secret, "csecret")
    Application.put_env(:app, :oidc_redirect_uri, "http://localhost:8787/auth/oidc/callback")
    Oidc.reset_discovery_cache()

    on_exit(fn ->
      Application.delete_env(:app, :allowed_users)
      System.delete_env("GOOGLE_CLIENT_ID")
      System.delete_env("GOOGLE_CLIENT_SECRET")

      for k <- [
            :oidc_issuer,
            :oidc_client_id,
            :oidc_client_secret,
            :oidc_redirect_uri,
            :oidc_req_opts
          ] do
        Application.delete_env(:app, k)
      end

      Oidc.reset_discovery_cache()
    end)

    :ok
  end

  # The label is provider-neutral on purpose. It said "Sign in with Google" while the button
  # already led to Authentik (c000745 changed the destination and not the copy), which told the
  # user the wrong thing about where their credentials were going. Naming the IdP here buys
  # nothing -- there is only one -- and would rot again at the next swap.
  test "GET /login renders a sign-in link that does not name a provider", %{conn: conn} do
    conn = get(conn, ~p"/login")
    html = html_response(conn, 200)

    assert html =~ ~p"/auth/login"
    assert html =~ "Sign in"
    refute html =~ "Google"
  end

  test "an unauthenticated request to / redirects to /login", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/login"
  end

  test "login redirects to Authentik and stores a state", %{conn: conn} do
    stub_discovery()

    conn = get(conn, ~p"/auth/login")
    assert redirected_to(conn, 302) =~ "auth.example.com"
    assert get_session(conn, :oidc_state) != nil
  end

  # T-2: a constant state would defeat the CSRF guard (login-CSRF: an attacker completes the
  # flow themselves, then navigates the victim to the callback with the attacker's code and the
  # constant, session-matching state). The mismatch test already covers the comparison; this
  # covers that the value being compared is actually unpredictable.
  test "each /auth/login request mints a different state", %{conn: conn} do
    stub_discovery()

    state1 = conn |> get(~p"/auth/login") |> get_session(:oidc_state)
    state2 = conn |> get(~p"/auth/login") |> get_session(:oidc_state)

    assert state1 != state2
  end

  test "login flashes and bounces back to /login when discovery is unreachable", %{conn: conn} do
    Application.put_env(:app, :oidc_req_opts, plug: {Req.Test, DiscoDownStub})
    Req.Test.stub(DiscoDownStub, fn conn -> Plug.Conn.send_resp(conn, 500, "nope") end)

    conn = get(conn, ~p"/auth/login")
    assert redirected_to(conn) == "/login"
    refute get_session(conn, :oidc_state)
  end

  test "the callback signs in an allowlisted subject", %{conn: conn} do
    stub_oidc_exchange(%{"sub" => "s-1", "email" => "alice@x.com", "name" => "Alice"})

    conn =
      conn
      |> init_test_session(%{oidc_state: "st"})
      |> get(~p"/auth/oidc/callback?state=st&code=c1")

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_id)
  end

  test "a mismatched state is refused and signs nobody in", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{oidc_state: "expected"})
      |> get(~p"/auth/oidc/callback?state=WRONG&code=c1")

    refute get_session(conn, :user_id)
  end

  test "an unlisted subject is refused", %{conn: conn} do
    stub_oidc_exchange(%{"sub" => "s-2", "email" => "stranger@x.com", "name" => "S"})

    conn =
      conn
      |> init_test_session(%{oidc_state: "st"})
      |> get(~p"/auth/oidc/callback?state=st&code=c1")

    assert redirected_to(conn) == "/login"
    refute get_session(conn, :user_id)
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "isn't allowed"
  end

  # I-3: a subject conflict means something entirely different from an allowlist denial (the
  # allowlisted email is already bound to a DIFFERENT oidc_subject -- e.g. the Authentik user
  # was recreated and reissued a new sub), and must not tell the operator to edit ALLOWED_USERS,
  # which cannot fix it. This test pins that the two refusals are DISTINGUISHABLE, not just both
  # "refused".
  test "a subject conflict (email already bound to a different subject) is refused with its own message",
       %{
         conn: conn
       } do
    # Seed a row already bound to a different subject than the one this login presents.
    {:ok, _user} =
      App.Users.upsert_from_oidc(%{sub: "s-original", email: "alice@x.com", name: "Alice"})

    stub_oidc_exchange(%{"sub" => "s-impostor", "email" => "alice@x.com", "name" => "Alice"})

    conn =
      conn
      |> init_test_session(%{oidc_state: "st"})
      |> get(~p"/auth/oidc/callback?state=st&code=c1")

    assert redirected_to(conn) == "/login"
    refute get_session(conn, :user_id)

    message = Phoenix.Flash.get(conn.assigns.flash, :error)
    refute message =~ "isn't allowed"
    assert message =~ "already linked to a different sign-in"
  end

  # Shipped 2026-09-02 and must survive the provider swap: a signed-out browser sent to /login
  # while opening a connector grant resumes that grant after signing in.
  test "signing in resumes a remembered request", %{conn: conn} do
    stub_oidc_exchange(%{"sub" => "s-1", "email" => "alice@x.com", "name" => "Alice"})

    conn =
      conn
      |> init_test_session(%{
        oidc_state: "st",
        user_return_to: "/auth/google/connect?return=app&calendar=read"
      })
      |> get(~p"/auth/oidc/callback?state=st&code=c1")

    assert redirected_to(conn) == "/auth/google/connect?return=app&calendar=read"
  end

  test "an app-flow login deep-links back with a code, not a token", %{conn: conn} do
    stub_oidc_exchange(%{"sub" => "s-1", "email" => "alice@x.com", "name" => "Alice"})

    conn =
      conn
      |> init_test_session(%{oidc_state: "st", oidc_return: "app"})
      |> get(~p"/auth/oidc/callback?state=st&code=c1")

    url = redirected_to(conn, 302)
    assert String.starts_with?(url, "orbital://auth?")
    code = URI.decode_query(URI.parse(url).query)["code"]
    assert is_binary(code)
    # The 30-day credential must NOT be in the URL.
    refute url =~ "token"
  end

  test "the code exchanges for a token that authenticates that user", %{conn: conn} do
    stub_oidc_exchange(%{"sub" => "s-1", "email" => "alice@x.com", "name" => "Alice"})

    conn =
      conn
      |> init_test_session(%{oidc_state: "st", oidc_return: "app"})
      |> get(~p"/auth/oidc/callback?state=st&code=c1")

    url = redirected_to(conn, 302)
    code = URI.decode_query(URI.parse(url).query)["code"]
    user = App.Users.get_by_email("alice@x.com")

    resp = post(build_conn(), ~p"/api/auth/exchange", %{"code" => code})
    assert %{"token" => token} = json_response(resp, 200)
    assert {:ok, user_id} = AppWeb.UserAuth.verify_socket_token(token)
    assert user_id == user.id
  end

  test "a replayed code is refused with the same error as an unknown one", %{conn: conn} do
    stub_oidc_exchange(%{"sub" => "s-1", "email" => "alice@x.com", "name" => "Alice"})

    conn =
      conn
      |> init_test_session(%{oidc_state: "st", oidc_return: "app"})
      |> get(~p"/auth/oidc/callback?state=st&code=c1")

    url = redirected_to(conn, 302)
    code = URI.decode_query(URI.parse(url).query)["code"]

    # Spend the code once so the replay below finds it already used.
    assert %{"token" => _} =
             json_response(post(build_conn(), ~p"/api/auth/exchange", %{"code" => code}), 200)

    a = post(build_conn(), ~p"/api/auth/exchange", %{"code" => code})
    b = post(build_conn(), ~p"/api/auth/exchange", %{"code" => "never-minted"})
    assert json_response(a, 401) == json_response(b, 401)
  end

  # Every way an APP-flow login can fail must still return the user to the app. Stranding them in
  # a browser tab on /login, with the app behind it showing no sign anything happened, is the
  # exact failure this flow was shaped to avoid -- and the branch that prevents it had no test:
  # deleting `if app_return?` from login_failed/2 left the whole file green.
  test "an app-flow state mismatch deep-links back with an error", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{oidc_state: "expected", oidc_return: "app"})
      |> get(~p"/auth/oidc/callback?state=WRONG&code=c1")

    assert redirected_to(conn, 302) == AppWeb.AppLink.auth_error()
    refute get_session(conn, :user_id)
  end

  test "an app-flow login by a non-allowlisted subject deep-links back with an error",
       %{conn: conn} do
    stub_oidc_exchange(%{"sub" => "s-9", "email" => "stranger@x.com", "name" => "S"})

    conn =
      conn
      |> init_test_session(%{oidc_state: "st", oidc_return: "app"})
      |> get(~p"/auth/oidc/callback?state=st&code=c1")

    assert redirected_to(conn, 302) == AppWeb.AppLink.auth_error()
    refute get_session(conn, :user_id)
  end

  test "an app-flow cancellation at the IdP deep-links back with an error", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{oidc_state: "st", oidc_return: "app"})
      |> get(~p"/auth/oidc/callback?state=st&error=access_denied")

    assert redirected_to(conn, 302) == AppWeb.AppLink.auth_error()
  end

  # The pre-hop failure: the browser never even leaves our domain, so without this the
  # app-launched tab just sits on /login.
  test "an app-flow login with an unreachable IdP deep-links back with an error", %{conn: conn} do
    Application.put_env(:app, :oidc_req_opts, plug: {Req.Test, LoginDiscoFailStub})
    Req.Test.stub(LoginDiscoFailStub, fn c -> Plug.Conn.send_resp(c, 500, "nope") end)
    App.Auth.Oidc.reset_discovery_cache()

    conn = get(conn, ~p"/auth/login?return=app")

    assert redirected_to(conn, 302) == AppWeb.AppLink.auth_error()
  end

  test "a web-flow login does NOT deep-link", %{conn: conn} do
    stub_oidc_exchange(%{"sub" => "s-1", "email" => "alice@x.com", "name" => "Alice"})

    conn =
      conn
      |> init_test_session(%{oidc_state: "st"})
      |> get(~p"/auth/oidc/callback?state=st&code=c1")

    assert redirected_to(conn) == ~p"/"
  end

  defp id_token(claims),
    do: "h." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> ".sig"

  defp stub_discovery do
    Application.put_env(:app, :oidc_req_opts, plug: {Req.Test, AuthDiscoStub})

    Req.Test.stub(AuthDiscoStub, fn conn ->
      Req.Test.json(conn, %{
        "authorization_endpoint" => "https://auth.example.com/application/o/authorize/",
        "token_endpoint" => "https://auth.example.com/application/o/token/"
      })
    end)
  end

  defp stub_oidc_exchange(claims) do
    stub_discovery()

    Req.Test.stub(AuthDiscoStub, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/token/") ->
          Req.Test.json(conn, %{"access_token" => "at", "id_token" => id_token(claims)})

        true ->
          Req.Test.json(conn, %{
            "authorization_endpoint" => "https://auth.example.com/application/o/authorize/",
            "token_endpoint" => "https://auth.example.com/application/o/token/"
          })
      end
    end)
  end
end
