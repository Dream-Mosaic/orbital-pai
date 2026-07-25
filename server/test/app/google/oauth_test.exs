defmodule App.Google.OAuthTest do
  # async: false — sets a global Req test plug + env vars via application/system env.
  use ExUnit.Case, async: false

  alias App.Google.OAuth

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

  test "authorize_url/2 requests exactly the passed scopes" do
    scopes = App.Google.Connectors.scopes_for(%{calendar: :read})
    url = OAuth.authorize_url("xyz-state", scopes)

    assert url =~ "https://accounts.google.com/o/oauth2/v2/auth?"
    assert url =~ "client_id=test-client-id"
    assert url =~ "access_type=offline"
    assert url =~ "include_granted_scopes=true"
    assert url =~ URI.encode_www_form("calendar.readonly")
    refute url =~ URI.encode_www_form("calendar.events")
    assert url =~ "state=xyz-state"
  end

  test "exchange_code parses tokens and id_token" do
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, OAuthStub})

    Req.Test.stub(OAuthStub, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "at-1",
        "refresh_token" => "rt-1",
        "expires_in" => 3599,
        "id_token" => "header.payload.sig"
      })
    end)

    assert {:ok, tokens} = OAuth.exchange_code("auth-code")
    assert tokens.access_token == "at-1"
    assert tokens.refresh_token == "rt-1"
    assert tokens.expires_in == 3599
    assert tokens.id_token == "header.payload.sig"
  end

  test "exchange_code returns unexpected_token_response for a non-token error body" do
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, OAuthStub})

    Req.Test.stub(OAuthStub, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => "invalid_client"})
    end)

    assert {:error, {:unexpected_token_response, %{"error" => "invalid_client"}}} =
             OAuth.exchange_code("auth-code")
  end

  test "refresh parses a new access token" do
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, OAuthStub})

    Req.Test.stub(OAuthStub, fn conn ->
      Req.Test.json(conn, %{"access_token" => "at-2", "expires_in" => 3599})
    end)

    assert {:ok, %{access_token: "at-2", expires_in: 3599}} = OAuth.refresh("rt-1")
  end

  test "refresh maps invalid_grant (revoked/expired refresh token)" do
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, OAuthStub})

    Req.Test.stub(OAuthStub, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => "invalid_grant"})
    end)

    assert {:error, :invalid_grant} = OAuth.refresh("dead-token")
  end

  test "email_from_id_token decodes the JWT payload" do
    payload = Base.url_encode64(~s({"email":"alice@example.com"}), padding: false)
    id_token = "anything.#{payload}.sig"

    assert OAuth.email_from_id_token(id_token) == "alice@example.com"
    assert OAuth.email_from_id_token(nil) == nil
    assert OAuth.email_from_id_token("garbage") == nil
  end

  test "exchange_code captures the granted scope from the token response" do
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, OAuthScopeStub})

    Req.Test.stub(OAuthScopeStub, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "at-1",
        "refresh_token" => "rt-1",
        "expires_in" => 3599,
        "id_token" => "h.p.s",
        "scope" => "https://www.googleapis.com/auth/calendar.events openid email"
      })
    end)

    assert {:ok, tokens} = OAuth.exchange_code("auth-code")
    assert tokens.scope =~ "calendar.events"
  end

  test "revoke posts the token to Google's revoke endpoint" do
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, RevokeStub})
    test_pid = self()

    Req.Test.stub(RevokeStub, fn conn ->
      send(test_pid, :revoked)
      Req.Test.json(conn, %{})
    end)

    assert :ok = OAuth.revoke("some-token")
    assert_received :revoked
  end
end
