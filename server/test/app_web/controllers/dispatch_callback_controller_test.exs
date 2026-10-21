defmodule AppWeb.DispatchCallbackControllerTest do
  use AppWeb.ConnCase, async: false
  alias App.{Dispatch, Users}

  @secret "s3cret"

  setup do
    Application.put_env(:app, :dispatch_callback_secret, @secret)
    on_exit(fn -> Application.delete_env(:app, :dispatch_callback_secret) end)
    Application.put_env(:app, :allowed_users, [%{email: "d@x.com", name: "D"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, u} = Users.upsert_allowed("d@x.com")
    {:ok, job} = Dispatch.create_job(u.id, "kalcode/x", 31)
    Phoenix.PubSub.subscribe(App.PubSub, "dispatch:#{u.id}")
    %{job: job}
  end

  defp sign(body, secret \\ @secret),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

  defp post_cb(conn, body, sig) do
    conn = put_req_header(conn, "content-type", "application/json")
    conn = if sig, do: put_req_header(conn, "x-dispatch-signature", sig), else: conn
    post(conn, "/api/dispatch/callback", body)
  end

  defp body(job, status, extra \\ %{}),
    do: Jason.encode!(Map.merge(%{job_id: to_string(job.id), status: status}, extra))

  test "valid signature changes status", %{conn: conn, job: job} do
    b = body(job, "pr", %{pr_url: "http://pr", summary: "done"})
    assert post_cb(conn, b, sign(b)).status == 204
    assert Dispatch.get_job(job.id).status == "pr"
    assert Dispatch.get_job(job.id).pr_url == "http://pr"
  end

  test "bad signature -> 401, no change", %{conn: conn, job: job} do
    b = body(job, "pr")
    assert post_cb(conn, b, sign(b, "wrong")).status == 401
    assert Dispatch.get_job(job.id).status == "queued"
  end

  test "no header -> 401", %{conn: conn, job: job} do
    assert post_cb(conn, body(job, "pr"), nil).status == 401
  end

  test "missing secret config -> 401", %{conn: conn, job: job} do
    Application.delete_env(:app, :dispatch_callback_secret)
    b = body(job, "pr")
    assert post_cb(conn, b, sign(b)).status == 401
    Application.put_env(:app, :dispatch_callback_secret, "")
    assert post_cb(conn, b, sign(b, "")).status == 401
  end

  test "unknown job -> 401", %{conn: conn} do
    b = Jason.encode!(%{job_id: "999999", status: "pr"})
    assert post_cb(conn, b, sign(b)).status == 401
  end

  test "replay -> 204 and exactly one broadcast", %{conn: conn, job: job} do
    b = body(job, "pr")
    assert post_cb(conn, b, sign(b)).status == 204
    assert post_cb(build_conn(), b, sign(b)).status == 204
    assert_received {:dispatch_job, %{status: "pr"}}
    refute_received {:dispatch_job, _}
  end

  test "valid signature on missing/unknown status -> 422", %{conn: conn, job: job} do
    b = body(job, "bogus")
    assert post_cb(conn, b, sign(b)).status == 422
  end

  test "malformed JSON is not a 2xx", %{conn: conn} do
    b = "{nope"

    resp =
      try do
        post_cb(conn, b, sign(b)).status
      rescue
        e in Plug.Parsers.ParseError -> Plug.Exception.status(e)
      end

    assert resp in 400..499
  end

  test "other API routes unaffected", %{conn: conn} do
    conn = post(conn, "/api/auth/exchange", %{"code" => "nope"})
    assert conn.status in 400..499
  end
end
