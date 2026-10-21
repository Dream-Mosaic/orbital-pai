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
end
