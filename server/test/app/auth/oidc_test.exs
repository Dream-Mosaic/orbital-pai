defmodule App.Auth.OidcTest do
  use ExUnit.Case, async: false

  alias App.Auth.Oidc

  setup do
    Application.put_env(:app, :oidc_issuer, "https://auth.example.com/application/o/orbital/")
    Application.put_env(:app, :oidc_client_id, "cid")
    Application.put_env(:app, :oidc_client_secret, "csecret")
    Application.put_env(:app, :oidc_redirect_uri, "http://localhost:8787/auth/oidc/callback")

    on_exit(fn ->
      for k <- [
            :oidc_issuer,
            :oidc_client_id,
            :oidc_client_secret,
            :oidc_redirect_uri,
            :oidc_req_opts
          ] do
        Application.delete_env(:app, k)
      end
    end)

    :ok
  end

  defp id_token(claims),
    do: "h." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> ".sig"

  # Discovery is fetched once and cached in :persistent_term, so every test that reaches it must
  # clear that cache first or the first test's stub leaks into the rest of the file.
  defp stub_discovery do
    Oidc.reset_discovery_cache()
    Application.put_env(:app, :oidc_req_opts, plug: {Req.Test, DiscoStub})

    Req.Test.stub(DiscoStub, fn conn ->
      Req.Test.json(conn, %{
        "issuer" => "https://auth.example.com/application/o/orbital/",
        "authorization_endpoint" => "https://auth.example.com/application/o/authorize/",
        "token_endpoint" => "https://auth.example.com/application/o/token/"
      })
    end)
  end

  test "authorize_url carries the client, redirect, scopes and state" do
    stub_discovery()
    assert {:ok, url} = Oidc.authorize_url("st8")
    # From the discovery document, NOT joined onto the issuer -- the real instance serves
    # /application/o/authorize/ while the issuer is /application/o/orbital/.
    assert String.starts_with?(url, "https://auth.example.com/application/o/authorize/")
    q = URI.decode_query(URI.parse(url).query)
    assert q["client_id"] == "cid"
    assert q["redirect_uri"] == "http://localhost:8787/auth/oidc/callback"
    assert q["response_type"] == "code"
    assert q["state"] == "st8"

    assert MapSet.new(String.split(q["scope"], " ")) ==
             MapSet.new(["openid", "email", "profile"])
  end

  # Discovery lives at <issuer>.well-known/..., so a missing trailing slash must not produce
  # ".../orbital.well-known/...".
  test "a slash-less issuer still finds the discovery document" do
    Application.put_env(:app, :oidc_issuer, "https://auth.example.com/application/o/orbital")
    stub_discovery()
    assert {:ok, url} = Oidc.authorize_url("s")
    assert url =~ "/application/o/authorize/"
  end

  # The stub inspects conn.request_path directly, so this proves the trim-trailing-slash join
  # actually lands on <issuer>/.well-known/openid-configuration, not merely that *a* request
  # happened -- a bare `Req.Test.json/2` stub (ignoring conn) would pass even if the URL join
  # were wrong (e.g. a stray "orbital.well-known" from a missing slash-trim).
  test "a slash-less issuer requests the discovery document at the right path" do
    Application.put_env(:app, :oidc_issuer, "https://auth.example.com/application/o/orbital")
    Oidc.reset_discovery_cache()
    Application.put_env(:app, :oidc_req_opts, plug: {Req.Test, DiscoPathStub})

    Req.Test.stub(DiscoPathStub, fn conn ->
      assert conn.request_path == "/application/o/orbital/.well-known/openid-configuration"

      Req.Test.json(conn, %{
        "authorization_endpoint" => "https://auth.example.com/application/o/authorize/",
        "token_endpoint" => "https://auth.example.com/application/o/token/"
      })
    end)

    assert {:ok, _} = Oidc.discovery()
  end

  test "an unreachable discovery document is an error, not a raise" do
    # The discovery cache is a global :persistent_term, so this test must start from a clean
    # cache itself -- otherwise a discovery already warmed by an earlier test in this file (via
    # stub_discovery/0) would answer from cache instead of ever reaching DiscoFailStub, and this
    # test would flake based on run order (ExUnit randomizes test order per seed).
    Oidc.reset_discovery_cache()
    Application.put_env(:app, :oidc_req_opts, plug: {Req.Test, DiscoFailStub})
    Req.Test.stub(DiscoFailStub, fn conn -> Plug.Conn.send_resp(conn, 500, "nope") end)
    assert {:error, _} = Oidc.discovery()
  end

  # Pins the authorize_url/1 contract: on a discovery outage it must return an error tuple, not
  # hand a caller (e.g. Task 4's `redirect(external: ...)`) a garbage string or crash.
  test "authorize_url returns an error, not a URL, when discovery is unreachable" do
    Oidc.reset_discovery_cache()
    Application.put_env(:app, :oidc_req_opts, plug: {Req.Test, AuthorizeDiscoFailStub})

    Req.Test.stub(AuthorizeDiscoFailStub, fn conn ->
      Plug.Conn.send_resp(conn, 500, "nope")
    end)

    assert {:error, :discovery_failed} = Oidc.authorize_url("st8")
  end

  # Reads the actual application/x-www-form-urlencoded POST body so the test proves what
  # exchange_code/1 sends, not just that a request happened.
  defp read_form_params(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {URI.decode_query(body), conn}
  end

  test "exchange_code posts the code and returns the tokens" do
    # exchange_code/1 also resolves the token endpoint via discovery, so warm the cache first
    # (deterministically, regardless of run order) before pointing the token POST at its own
    # stub -- the discovery fetch and the token exchange hit different mock endpoints.
    stub_discovery()
    assert {:ok, _} = Oidc.discovery()
    Application.put_env(:app, :oidc_req_opts, plug: {Req.Test, OidcTokenStub})

    Req.Test.stub(OidcTokenStub, fn conn ->
      {params, conn} = read_form_params(conn)
      assert params["code"] == "code-1"
      assert params["client_id"] == "cid"
      assert params["client_secret"] == "csecret"
      assert params["redirect_uri"] == "http://localhost:8787/auth/oidc/callback"
      assert params["grant_type"] == "authorization_code"

      Req.Test.json(conn, %{
        "access_token" => "at",
        "id_token" => id_token(%{"sub" => "s-1", "email" => "a@b.com"})
      })
    end)

    assert {:ok, %{access_token: "at", id_token: idt}} = Oidc.exchange_code("code-1")
    assert is_binary(idt)
  end

  test "a non-200 token response is an error, not a crash" do
    # Same reasoning as above: warm discovery deterministically before stubbing the token
    # endpoint to fail.
    stub_discovery()
    assert {:ok, _} = Oidc.discovery()
    Application.put_env(:app, :oidc_req_opts, plug: {Req.Test, OidcFailStub})

    Req.Test.stub(OidcFailStub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "invalid_client"})
    end)

    assert {:error, _} = Oidc.exchange_code("code-1")
  end

  test "claims_from_id_token reads sub, email and name" do
    token = id_token(%{"sub" => "s-9", "email" => "A@B.com", "name" => "David"})

    assert {:ok, %{sub: "s-9", email: "A@B.com", name: "David"}} =
             Oidc.claims_from_id_token(token)
  end

  # The predicted operator error: an Authentik user created without an email.
  # It must fail cleanly here rather than surfacing as a confusing allowlist denial.
  test "a token with no email claim is an error" do
    assert {:error, _} = Oidc.claims_from_id_token(id_token(%{"sub" => "s-9"}))
  end

  test "a token with no sub is an error" do
    assert {:error, _} = Oidc.claims_from_id_token(id_token(%{"email" => "a@b.com"}))
  end

  test "a malformed token is an error, not a crash" do
    assert {:error, _} = Oidc.claims_from_id_token("not-a-jwt")
  end

  test "configured? is false when the client id is missing" do
    Application.delete_env(:app, :oidc_client_id)
    refute Oidc.configured?()
  end

  # The unsigned-id_token argument (moduledoc) holds only because the token travels over TLS
  # end to end. A non-https issuer would silently void that premise.
  test "a non-https issuer is refused, not raised" do
    Application.put_env(:app, :oidc_issuer, "http://auth.example.com/application/o/orbital/")
    Oidc.reset_discovery_cache()

    assert {:error, :insecure_issuer} = Oidc.discovery()
  end

  # Except for a loopback host, so a locally self-hosted IdP still works during development.
  test "a loopback issuer over http is allowed" do
    Application.put_env(:app, :oidc_issuer, "http://localhost:9000/application/o/orbital/")
    Oidc.reset_discovery_cache()
    Application.put_env(:app, :oidc_req_opts, plug: {Req.Test, LoopbackDiscoStub})

    Req.Test.stub(LoopbackDiscoStub, fn conn ->
      Req.Test.json(conn, %{
        "authorization_endpoint" => "http://localhost:9000/application/o/authorize/",
        "token_endpoint" => "http://localhost:9000/application/o/token/"
      })
    end)

    assert {:ok, _} = Oidc.discovery()
  end
end
