defmodule AppWeb.DispatchCallbackControllerTest do
  use AppWeb.ConnCase, async: false
  import ExUnit.CaptureLog
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
    b = body(job, "pr", %{summary: "SECRETSUMMARY"})
    bad = sign(b, "wrong")

    log = capture_log(fn -> assert post_cb(conn, b, bad).status == 401 end)
    assert log =~ "callback rejected (bad signature)"
    refute log =~ bad
    refute log =~ "SECRETSUMMARY"
    assert Dispatch.get_job(job.id).status == "queued"
  end

  test "no header -> 401", %{conn: conn, job: job} do
    log = capture_log(fn -> assert post_cb(conn, body(job, "pr"), nil).status == 401 end)
    assert log =~ "callback rejected (no signature)"
  end

  test "missing secret config -> 401", %{conn: conn, job: job} do
    Application.delete_env(:app, :dispatch_callback_secret)
    b = body(job, "pr")
    log = capture_log(fn -> assert post_cb(conn, b, sign(b)).status == 401 end)
    assert log =~ "no secret configured"
    Application.put_env(:app, :dispatch_callback_secret, "")
    capture_log(fn -> assert post_cb(build_conn(), b, sign(b, "")).status == 401 end)
  end

  test "unknown job -> 401", %{conn: conn} do
    b = Jason.encode!(%{job_id: "999999", status: "pr"})
    log = capture_log(fn -> assert post_cb(conn, b, sign(b)).status == 401 end)
    assert log =~ "callback rejected (unknown job)"
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

  test "HMAC over non-canonical bytes verifies (raw bytes are used)", %{conn: conn, job: job} do
    b = ~s({  "status" :  "running",\n "job_id":"#{job.id}"  })
    assert post_cb(conn, b, sign(b)).status == 204
    assert Dispatch.get_job(job.id).status == "running"
  end

  test "a query-string field is ignored: only the signed body counts", %{conn: conn, job: job} do
    b = body(job, "pr", %{summary: "done"})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-dispatch-signature", sign(b))
      |> post("/api/dispatch/callback?pr_url=https://evil.test/pr&status=failed", b)

    assert conn.status == 204
    assert %{status: "pr", pr_url: nil, summary: "done"} = Dispatch.get_job(job.id)
  end

  test "a signed body naming another repo or issue is refused", %{conn: conn, job: job} do
    for extra <- [%{repo: "kalcode/other"}, %{issue: 32}, %{repo: "kalcode/x", issue: "30"}] do
      b = body(job, "pr", extra)

      log = capture_log(fn -> assert post_cb(build_conn(), b, sign(b)).status == 401 end)
      assert log =~ "[dispatch] callback rejected (job mismatch)"
    end

    assert Dispatch.get_job(job.id).status == "queued"

    # The matching repo and issue (an integer, or its string) are accepted.
    b = body(job, "running", %{repo: "kalcode/x", issue: 31})
    assert post_cb(conn, b, sign(b)).status == 204
    b = body(job, "pr", %{repo: "kalcode/x", issue: "31"})
    assert post_cb(build_conn(), b, sign(b)).status == 204
    assert Dispatch.get_job(job.id).status == "pr"
  end

  # Verbatim output of claude-dispatch's `scripts/callback.sh --dry-run pr …` with
  # JOB_ID=42, REPO=kalcode/unwritten-chronicles, ISSUE=31, RUN_URL=…/runs/57 and a test
  # secret: the exact bytes and signature the box sends.
  @track_a_secret "test-secret"
  @track_a_sig "sha256=1818ace28d2ae39a158ca863bccbc4a807c4ffc0b39c8b48a65e6321bad27478"
  @track_a_body ~s({"job_id":"42","status":"pr","repo":"kalcode/unwritten-chronicles","issue":31,) <>
                  ~s("branch":"claude/31-fix-truncated-filter-r57",) <>
                  ~s("pr_url":"https://code.clausens.cloud/kalcode/unwritten-chronicles/pulls/40",) <>
                  ~s("summary":"Fixed the truncated action filter. Tests pass.",) <>
                  ~s("run_url":"https://code.clausens.cloud/kalcode/claude-dispatch/actions/runs/57"})

  test "the dispatcher's real callback body and signature are accepted", %{conn: conn, job: job} do
    Application.put_env(:app, :dispatch_callback_secret, @track_a_secret)
    App.Repo.delete_all(Dispatch.Job)

    App.Repo.insert!(%Dispatch.Job{
      id: 42,
      user_id: job.user_id,
      repo: "kalcode/unwritten-chronicles",
      issue: 31
    })

    assert post_cb(conn, @track_a_body, @track_a_sig).status == 204

    assert %{
             status: "pr",
             branch: "claude/31-fix-truncated-filter-r57",
             pr_url: "https://code.clausens.cloud/kalcode/unwritten-chronicles/pulls/40",
             summary: "Fixed the truncated action filter. Tests pass.",
             run_url: "https://code.clausens.cloud/kalcode/claude-dispatch/actions/runs/57"
           } = Dispatch.get_job(42)
  end

  test "missing job_id -> 422", %{conn: conn} do
    b = Jason.encode!(%{status: "pr"})
    assert post_cb(conn, b, sign(b)).status == 422
  end

  test "body reader caches only the callback path" do
    {:ok, other} = {:ok, Plug.Test.conn(:post, "/api/other", "{}")}
    {:ok, _, other} = AppWeb.CacheBodyReader.read_body(other, [])
    refute Map.has_key?(other.assigns, :raw_body)
    cb = Plug.Test.conn(:post, "/api/dispatch/callback", "{}")
    {:ok, "{}", cb} = AppWeb.CacheBodyReader.read_body(cb, [])
    assert cb.assigns.raw_body == "{}"
  end

  test "other API routes still parse JSON", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/auth/exchange", ~s({"code":"nope"}))

    assert conn.status in 400..499
  end
end
