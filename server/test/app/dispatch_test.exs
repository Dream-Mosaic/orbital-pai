defmodule App.DispatchTest do
  use App.DataCase, async: false
  alias App.{Dispatch, Users}

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "d@x.com", name: "D"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, u} = Users.upsert_allowed("d@x.com")
    {:ok, job} = Dispatch.create_job(u.id, "kalcode/x", 31)
    Phoenix.PubSub.subscribe(App.PubSub, "dispatch")
    Phoenix.PubSub.subscribe(App.PubSub, "dispatch:#{u.id}")
    %{u: u, job: job}
  end

  test "create starts queued and is the active job", %{job: job} do
    assert job.status == "queued"
    assert Dispatch.active_job("kalcode/x", 31).id == job.id
    assert Dispatch.active_job("kalcode/x", 32) == nil
  end

  test "mark_dispatched stores run info", %{job: job} do
    {:ok, j} = Dispatch.mark_dispatched(job, %{run_id: 9, run_number: 3})
    assert {j.run_id, j.run_number} == {9, 3}
  end

  test "queued -> running -> pr, broadcasting on both topics", %{job: job} do
    assert {:ok, j, :changed} = Dispatch.apply_callback(job, %{"status" => "running"})
    assert_received {:dispatch_job, %{status: "running"}}
    assert_received {:dispatch_job, %{status: "running"}}

    assert {:ok, j, :changed} =
             Dispatch.apply_callback(j, %{
               "status" => "pr",
               "pr_url" => "u",
               "summary" => "s",
               "branch" => "b"
             })

    assert {j.pr_url, j.summary, j.branch} == {"u", "s", "b"}
    refute Dispatch.active_job("kalcode/x", 31)
  end

  test "idempotent: same status and anything after an end state", %{job: job} do
    {:ok, j, :changed} = Dispatch.apply_callback(job, %{"status" => "running"})
    assert {:ok, _, :unchanged} = Dispatch.apply_callback(j, %{"status" => "running"})
    {:ok, j, :changed} = Dispatch.apply_callback(j, %{"status" => "failed", "reason" => "r"})
    assert {:ok, j2, :unchanged} = Dispatch.apply_callback(j, %{"status" => "running"})
    assert j2.status == "failed"
    assert {:ok, _, :unchanged} = Dispatch.apply_callback(j, %{"status" => "pr"})
  end

  test "queued may jump straight to an end state; running never goes back", %{job: job} do
    assert {:ok, %{status: "draft"}, :changed} = Dispatch.apply_callback(job, %{status: "draft"})
  end

  test "a callback's run_url is stored, from the first callback that has one", %{job: job} do
    url = "https://code.test/kalcode/claude-dispatch/actions/runs/57"
    {:ok, j, :changed} = Dispatch.apply_callback(job, %{"status" => "running", "run_url" => url})
    assert j.run_url == url
    {:ok, j, :changed} = Dispatch.apply_callback(j, %{"status" => "pr"})
    assert j.run_url == url
  end

  test "end_state?" do
    refute Dispatch.end_state?("queued")
    refute Dispatch.end_state?("running")
    for s <- ~w(pr draft blocked failed usage_limit lost), do: assert(Dispatch.end_state?(s))
  end

  test "stale_jobs and list_jobs", %{u: u, job: job} do
    assert Dispatch.stale_jobs(DateTime.utc_now(), 60_000) == []
    later = DateTime.add(DateTime.utc_now(), 3600, :second)
    assert [%{id: id}] = Dispatch.stale_jobs(later, 60_000)
    assert id == job.id
    assert [%{id: ^id}] = Dispatch.list_jobs(u.id, limit: 5)
  end

  test "a stale struct cannot overwrite a committed end state", %{job: job} do
    {:ok, stale, :changed} = Dispatch.apply_callback(job, %{"status" => "running"})
    {:ok, _, :changed} = Dispatch.apply_callback(Dispatch.get_job(job.id), %{"status" => "pr"})
    assert_received {:dispatch_job, %{status: "running"}}
    assert_received {:dispatch_job, %{status: "running"}}
    assert_received {:dispatch_job, %{status: "pr"}}
    assert_received {:dispatch_job, %{status: "pr"}}

    assert {:ok, j, :unchanged} = Dispatch.set_status(stale, "failed", "x")
    assert j.status == "pr"
    assert Dispatch.get_job(job.id).status == "pr"
    refute_received {:dispatch_job, _}
  end

  test "identical end callbacks applied twice broadcast once", %{job: job} do
    assert {:ok, _, :changed} = Dispatch.apply_callback(job, %{status: "failed"})
    assert {:ok, _, :unchanged} = Dispatch.apply_callback(job, %{status: "failed"})
    assert_received {:dispatch_job, _}
    assert_received {:dispatch_job, _}
    refute_received {:dispatch_job, _}
  end

  test "invalid status is rejected without a write", %{job: job} do
    assert {:error, :invalid_status} = Dispatch.apply_callback(job, %{status: "bogus"})
    assert {:error, :invalid_status} = Dispatch.apply_callback(job, %{status: "queued"})
    assert {:error, :invalid_status} = Dispatch.apply_callback(job, %{})
    assert Dispatch.get_job(job.id).status == "queued"
    assert {:ok, %{status: "lost"}, :changed} = Dispatch.set_status(job, "lost")
  end

  test "active_jobs lists a repo's queued and running jobs, newest first", %{u: u, job: job} do
    {:ok, other} = Dispatch.create_job(u.id, "kalcode/x", 32)
    {:ok, _, :changed} = Dispatch.apply_callback(other, %{status: "running"})
    {:ok, done} = Dispatch.create_job(u.id, "kalcode/x", 33)
    {:ok, _, :changed} = Dispatch.apply_callback(done, %{status: "pr"})
    {:ok, _elsewhere} = Dispatch.create_job(u.id, "kalcode/y", 31)

    assert [%{issue: 32, status: "running"}, %{issue: 31, status: "queued"}] =
             Dispatch.active_jobs("kalcode/x")

    assert job.issue == 31
  end

  test "create_job_unless_active refuses an issue that already has an active job", %{
    u: u,
    job: job
  } do
    assert {:error, {:active, %{id: id}}} =
             Dispatch.create_job_unless_active(u.id, "kalcode/x", 31)

    assert id == job.id

    assert {:ok, %{issue: 32, status: "queued"} = fresh} =
             Dispatch.create_job_unless_active(u.id, "kalcode/x", 32)

    assert_received {:dispatch_job, %{issue: 32}}
    assert Dispatch.active_job("kalcode/x", 32).id == fresh.id

    # Once the old job has ended, the issue can be started again.
    {:ok, _, :changed} = Dispatch.set_status(job, "failed", "r")
    assert {:ok, %{issue: 31}} = Dispatch.create_job_unless_active(u.id, "kalcode/x", 31)
  end
end
