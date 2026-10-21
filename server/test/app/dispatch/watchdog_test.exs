defmodule App.Dispatch.WatchdogTest do
  use App.DataCase, async: false

  alias App.{Dispatch, Users}
  alias App.Dispatch.Watchdog

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "d@x.com", name: "D"}])
    Application.put_env(:app, :ntfy, %{url: "https://ntfy.test", topic: "henry", token: nil})
    Application.put_env(:app, :ntfy_req_opts, plug: {Req.Test, NtfyStub})
    Application.put_env(:app, :dispatch_req_opts, plug: {Req.Test, ForgeStub})
    Application.put_env(:app, :forge, %{url: "https://forge.test", token: "t"})

    on_exit(fn ->
      for k <- [:allowed_users, :ntfy, :ntfy_req_opts, :dispatch_req_opts, :forge],
          do: Application.delete_env(:app, k)
    end)

    Req.Test.stub(NtfyStub, fn conn -> Plug.Conn.send_resp(conn, 200, "{}") end)
    {:ok, u} = Users.upsert_allowed("d@x.com")
    {:ok, job} = Dispatch.create_job(u.id, "kalcode/x", 31)
    {:ok, job} = Dispatch.mark_dispatched(job, %{run_id: 9, run_number: 3})
    %{job: job}
  end

  defp run_stub(status, stopped \\ nil) do
    Req.Test.stub(ForgeStub, fn conn ->
      Req.Test.json(conn, %{
        "status" => status,
        "conclusion" => nil,
        "stopped" => stopped && DateTime.to_iso8601(stopped)
      })
    end)
  end

  defp later(min), do: DateTime.add(DateTime.utc_now(), min * 60, :second)

  for st <- ~w(success failure cancelled) do
    test "a #{st} run with no callback fails and is notified", %{job: job} do
      now = later(20)
      run_stub(unquote(st), DateTime.add(now, -300, :second))
      Watchdog.tick(now)
      j = Dispatch.get_job(job.id)
      assert j.status == "failed"
      assert j.reason == "the job ended without reporting back — check the issue for a PR"
      assert j.notified_at
    end
  end

  test "a run that stopped 1 minute ago is within the callback grace", %{job: job} do
    now = later(20)
    run_stub("success", DateTime.add(now, -60, :second))
    Watchdog.tick(now)
    assert Dispatch.get_job(job.id).status == "queued"
  end

  test "a finished run with unknown stop time fails once the job is 10 minutes old", %{job: job} do
    run_stub("failure")
    Watchdog.tick(later(5))
    assert Dispatch.get_job(job.id).status == "queued"
    Watchdog.tick(later(11))
    assert Dispatch.get_job(job.id).status == "failed"
  end

  for st <- ~w(running waiting) do
    test "a #{st} run is untouched", %{job: job} do
      run_stub(unquote(st))
      Watchdog.tick(later(20))
      assert Dispatch.get_job(job.id).status == "queued"
    end
  end

  test "a 5-hour-old job whose run is still waiting is untouched", %{job: job} do
    run_stub("waiting")
    Watchdog.tick(later(300))
    j = Dispatch.get_job(job.id)
    assert j.status == "queued"
    assert j.notified_at == nil
  end

  test "a run the forge no longer knows is lost and notified", %{job: job} do
    Req.Test.stub(ForgeStub, fn conn -> Plug.Conn.send_resp(conn, 404, "x") end)
    Watchdog.tick(later(20))
    j = Dispatch.get_job(job.id)
    assert j.status == "lost"
    assert j.reason == "the run disappeared"
    assert j.notified_at
  end

  describe "without a run_id" do
    setup do
      {:ok, u} = Users.upsert_allowed("d@x.com")
      {:ok, job} = Dispatch.create_job(u.id, "kalcode/x", 32)
      run_stub("waiting")
      %{bare: job}
    end

    test "7 hours of silence is lost", %{bare: job} do
      Watchdog.tick(later(7 * 60))
      j = Dispatch.get_job(job.id)
      assert j.status == "lost"
      assert j.reason == "never heard from the run"
    end

    test "2 hours is untouched", %{bare: job} do
      Watchdog.tick(later(120))
      assert Dispatch.get_job(job.id).status == "queued"
    end
  end

  test "a job already at an end state is left alone", %{job: job} do
    {:ok, _, :changed} = Dispatch.apply_callback(job, %{status: "pr"})
    run_stub("success", DateTime.add(later(200), -600, :second))
    Watchdog.tick(later(200))
    assert Dispatch.get_job(job.id).status == "pr"
  end

  test "a forge error leaves the job alone until it is 24 hours old", %{job: job} do
    Req.Test.stub(ForgeStub, fn conn -> Plug.Conn.send_resp(conn, 500, "x") end)
    Watchdog.tick(later(10 * 60))
    assert Dispatch.get_job(job.id).status == "queued"
    Watchdog.tick(later(25 * 60))
    j = Dispatch.get_job(job.id)
    assert j.status == "lost"
    assert j.reason == "couldn't check on the run"
  end
end
