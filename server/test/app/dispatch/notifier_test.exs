defmodule App.Dispatch.NotifierTest do
  use App.DataCase, async: false
  import ExUnit.CaptureLog

  alias App.{Dispatch, Users}
  alias App.Agenda.Item
  alias App.Dispatch.Notifier

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "d@x.com", name: "D"}])
    Application.put_env(:app, :ntfy, %{url: "https://ntfy.test", topic: "henry", token: nil})
    Application.put_env(:app, :ntfy_req_opts, plug: {Req.Test, NtfyStub})

    Application.put_env(:app, :forge, %{
      url: "https://forge.test",
      token: "t",
      dispatch_repo: "kalcode/claude-dispatch"
    })

    on_exit(fn ->
      for k <- [:allowed_users, :ntfy, :ntfy_req_opts, :forge],
          do: Application.delete_env(:app, k)
    end)

    {:ok, u} = Users.upsert_allowed("d@x.com")
    {:ok, job} = Dispatch.create_job(u.id, "kalcode/chronicles", 31)
    {:ok, job} = Dispatch.mark_dispatched(job, %{run_id: 9, run_number: 12})
    Phoenix.PubSub.subscribe(App.PubSub, "agenda:#{u.id}")
    test_pid = self()

    Req.Test.stub(NtfyStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(test_pid, {:ntfy, body, Map.new(conn.req_headers)})
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    %{u: u, job: job}
  end

  defp finish(job, attrs) do
    {:ok, j, :changed} = Dispatch.apply_callback(job, attrs)
    j
  end

  test "a pr job sends one ntfy and one wall line, once", %{job: job} do
    j =
      finish(job, %{
        status: "pr",
        pr_url: "https://forge.test/kalcode/chronicles/pulls/5",
        summary: "Added dark mode, and fixed the toggle."
      })

    assert :notified = Notifier.notify(j)
    assert_received {:ntfy, "Added dark mode, and fixed the toggle.", h}
    assert h["title"] == "PR ready: chronicles #31"
    assert h["click"] == "https://forge.test/kalcode/chronicles/pulls/5"

    assert_received {:agenda_due,
                     %Item{kind: :heads_up, canned: true, deliver: :when_idle, prompt: prompt}}

    assert prompt == "Claude's PR for chronicles thirty-one is up — Added dark mode."
    assert Dispatch.get_job(j.id).notified_at

    assert :already_notified = Notifier.notify(j)
    assert :already_notified = Notifier.notify(Dispatch.get_job(j.id))
    refute_received {:ntfy, _, _}
    refute_received {:agenda_due, _}
  end

  test "running and queued jobs notify nothing", %{job: job} do
    assert :skipped = Notifier.notify(job)
    j = finish(job, %{status: "running"})
    assert :skipped = Notifier.notify(j)
    refute_received {:ntfy, _, _}
    refute_received {:agenda_due, _}
    assert Dispatch.get_job(j.id).notified_at == nil
  end

  test "click falls back to the issue, then the run", %{job: job} do
    j = finish(job, %{status: "failed", reason: "step tests failed"})
    Notifier.notify(j)
    assert_received {:ntfy, "step tests failed", h}
    assert h["title"] == "Claude job failed: chronicles #31"
    assert h["click"] == "https://forge.test/kalcode/chronicles/issues/31"
  end

  test "click is the run url when the forge has no issue url basis", %{job: job} do
    assert Notifier.click(%{job | pr_url: nil, issue: nil}) ==
             "https://forge.test/kalcode/claude-dispatch/actions/runs/12"
  end

  describe "with a LAN API base and a public link base" do
    setup do
      Application.put_env(:app, :forge, %{
        url: "http://192.168.50.249:3000",
        public_url: "https://code.test",
        token: "t",
        dispatch_repo: "kalcode/claude-dispatch"
      })
    end

    test "the issue Click uses the public base", %{job: job} do
      j = finish(job, %{status: "failed", reason: "step tests failed"})
      Notifier.notify(j)
      assert_received {:ntfy, _, h}
      assert h["click"] == "https://code.test/kalcode/chronicles/issues/31"
    end

    test "the run Click uses the public base", %{job: job} do
      assert Notifier.click(%{job | pr_url: nil, issue: nil}) ==
               "https://code.test/kalcode/claude-dispatch/actions/runs/12"
    end

    test "the callback's own run_url is preferred over a built one", %{job: job} do
      j = %{job | pr_url: nil, issue: nil, run_url: "https://code.test/kalcode/d/actions/runs/7"}
      assert Notifier.click(j) == "https://code.test/kalcode/d/actions/runs/7"
    end
  end

  test "titles per status", %{job: job} do
    for {s, t} <- [
          {"draft", "Draft PR"},
          {"blocked", "Claude is stuck"},
          {"failed", "Claude job failed"},
          {"usage_limit", "Claude hit your usage limit"},
          {"lost", "Claude job went quiet"}
        ] do
      assert Notifier.title(%{job | status: s}) == "#{t}: chronicles #31"
    end
  end

  test "ntfy failure still delivers the wall line and sets notified_at", %{job: job} do
    Req.Test.stub(NtfyStub, fn conn -> Plug.Conn.send_resp(conn, 500, "no") end)
    j = finish(job, %{status: "blocked", reason: "needs a decision"})

    log = capture_log(fn -> assert :notified = Notifier.notify(j) end)
    assert log =~ "ntfy"

    assert_received {:agenda_due,
                     %Item{prompt: "Claude is stuck on chronicles thirty-one — needs a decision."}}

    assert Dispatch.get_job(j.id).notified_at
  end

  test "the GenServer notifies on a broadcast", %{job: job} do
    Req.Test.set_req_test_to_shared()
    start_supervised!(Notifier)
    Dispatch.apply_callback(job, %{status: "draft", summary: "Half done"})
    assert_receive {:agenda_due, %Item{}}, 1000
  end

  test "the spoken line has no markdown or URLs, and expires in 2 hours", %{job: job} do
    j =
      finish(job, %{
        status: "pr",
        summary: "**Fixed** the [login bug](https://x.test/a) see https://x.test/b, done"
      })

    Notifier.notify(j)
    assert_received {:agenda_due, %Item{prompt: prompt, expires_at: exp}}
    assert prompt == "Claude's PR for chronicles thirty-one is up — Fixed the login bug see."
    assert_in_delta DateTime.diff(exp, DateTime.utc_now()), 7200, 5
  end

  test "a heading marker and backticks are stripped", %{job: job} do
    j = finish(job, %{status: "draft", summary: "## Use `foo` helper"})
    Notifier.notify(j)
    assert_received {:agenda_due, %Item{prompt: p}}
    assert p =~ "— Use foo helper."
  end
end
