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

  defp run_stub(status) do
    Req.Test.stub(ForgeStub, fn conn ->
      Req.Test.json(conn, %{"status" => status, "conclusion" => "success"})
    end)
  end

  defp later(min), do: DateTime.add(DateTime.utc_now(), min * 60, :second)

  test "a completed run with no callback fails and is notified", %{job: job} do
    run_stub("completed")
    Watchdog.tick(later(10))
    j = Dispatch.get_job(job.id)
    assert j.status == "failed"
    assert j.reason == "the job ended without reporting back"
    assert j.notified_at
  end

  test "a job over 130 minutes becomes lost and is notified", %{job: job} do
    run_stub("in_progress")
    Watchdog.tick(later(131))
    j = Dispatch.get_job(job.id)
    assert j.status == "lost"
    assert j.notified_at
  end

  test "a running job under 130 minutes is untouched", %{job: job} do
    run_stub("in_progress")
    Watchdog.tick(later(129))
    j = Dispatch.get_job(job.id)
    assert j.status == "queued"
    assert j.notified_at == nil
  end

  test "a job already at an end state is left alone", %{job: job} do
    {:ok, _, :changed} = Dispatch.apply_callback(job, %{status: "pr"})
    run_stub("completed")
    Watchdog.tick(later(200))
    assert Dispatch.get_job(job.id).status == "pr"
  end

  test "a forge error leaves the job to the age check", %{job: job} do
    Req.Test.stub(ForgeStub, fn conn -> Plug.Conn.send_resp(conn, 500, "x") end)
    Watchdog.tick(later(10))
    assert Dispatch.get_job(job.id).status == "queued"
  end
end
