defmodule App.Dispatch do
  @moduledoc """
  Dispatch jobs: create, track and update. Every change broadcasts `{:dispatch_job, job}` on
  `"dispatch:<user_id>"` and the global `"dispatch"` topic (the notifier subscribes to the latter).
  """
  import Ecto.Query

  alias App.Dispatch.Job
  alias App.Repo

  @active ~w(queued running)
  @callback_statuses ~w(running pr draft blocked failed usage_limit)
  @valid_statuses @callback_statuses ++ ["lost"]

  def callback_statuses, do: @callback_statuses

  @doc "End states are everything except queued and running."
  def end_state?(status), do: status not in @active

  def get_job(id), do: Repo.get(Job, id)

  def create_job(user_id, repo, issue) do
    %Job{user_id: user_id, repo: repo, issue: issue}
    |> Repo.insert()
    |> broadcast()
  end

  def active_job(repo, issue) do
    Repo.one(
      from j in Job,
        where: j.repo == ^repo and j.issue == ^issue and j.status in @active,
        order_by: [desc: j.id],
        limit: 1
    )
  end

  @doc "A repo's queued and running jobs, newest first."
  def active_jobs(repo) do
    Repo.all(
      from j in Job, where: j.repo == ^repo and j.status in @active, order_by: [desc: j.id]
    )
  end

  @doc """
  Create a job unless the issue already has an active one: `{:ok, job}` or
  `{:error, {:active, job}}`. The check and the insert share one IMMEDIATE transaction, so two
  starts racing on the same issue can't both create (a deferred read-then-write would get
  SQLite's BUSY_SNAPSHOT instead).
  """
  def create_job_unless_active(user_id, repo, issue) do
    Repo.transaction(
      fn ->
        case active_job(repo, issue) do
          nil -> Repo.insert!(%Job{user_id: user_id, repo: repo, issue: issue})
          job -> Repo.rollback({:active, job})
        end
      end,
      mode: :immediate
    )
    |> broadcast()
  end

  @doc """
  Mark a job as already announced, so the notifier skips it. True only for the caller that
  set it: a conditional `update_all`, so two claims can't both win.
  """
  def claim_notice(id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {n, _} =
      Repo.update_all(from(j in Job, where: j.id == ^id and is_nil(j.notified_at)),
        set: [notified_at: now]
      )

    n == 1
  end

  @doc "Undo `claim_notice/1`, so the notifier may announce the job after all."
  def release_notice(id) do
    Repo.update_all(from(j in Job, where: j.id == ^id), set: [notified_at: nil])
    :ok
  end

  def mark_dispatched(job, %{run_id: run_id, run_number: run_number}) do
    job
    |> Ecto.Changeset.change(run_id: run_id, run_number: run_number)
    |> Repo.update()
    |> broadcast()
  end

  @doc """
  Apply a callback map (string or atom keys). Idempotent: the same status, or any status after
  an end state, is `:unchanged`. The only transition out of a running job is to an end state.
  The transition is decided against a FRESH row inside an immediate transaction (the passed
  struct may be stale), and the broadcast happens after commit, only on `:changed`.
  """
  def apply_callback(%Job{id: id}, attrs) do
    status = fetch(attrs, :status)

    if status in @valid_statuses do
      result =
        Repo.transaction(
          fn ->
            fresh = Repo.get!(Job, id)

            if transition?(fresh.status, status) do
              {:changed, fresh |> Ecto.Changeset.change(changes(status, attrs)) |> Repo.update!()}
            else
              {:unchanged, fresh}
            end
          end,
          mode: :immediate
        )

      case result do
        {:ok, {:changed, job}} ->
          broadcast({:ok, job})
          {:ok, job, :changed}

        {:ok, {:unchanged, job}} ->
          {:ok, job, :unchanged}

        error ->
          error
      end
    else
      {:error, :invalid_status}
    end
  end

  defp transition?(current, status) do
    cond do
      status == current -> false
      end_state?(current) -> false
      current == "running" and not end_state?(status) -> false
      true -> true
    end
  end

  defp changes(status, attrs) do
    [status: status] ++
      for k <- [:branch, :pr_url, :summary, :reason],
          v = fetch(attrs, k),
          is_binary(v),
          do: {k, v}
  end

  defp fetch(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  def list_jobs(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Repo.all(from j in Job, where: j.user_id == ^user_id, order_by: [desc: j.id], limit: ^limit)
  end

  @doc "Active jobs created more than `older_than_ms` before `now`."
  def stale_jobs(now, older_than_ms) do
    cutoff = now |> DateTime.add(-older_than_ms, :millisecond) |> DateTime.truncate(:second)

    Repo.all(
      from j in Job, where: j.status in @active and j.inserted_at < ^cutoff, order_by: j.id
    )
  end

  @doc "Set a status directly (watchdog), same broadcast and end-state guard."
  def set_status(job, status, reason \\ nil) do
    apply_callback(job, %{status: status, reason: reason})
  end

  defp broadcast({:ok, job} = ok) do
    msg = {:dispatch_job, job}
    Phoenix.PubSub.broadcast(App.PubSub, "dispatch:#{job.user_id}", msg)
    Phoenix.PubSub.broadcast(App.PubSub, "dispatch", msg)
    ok
  end

  defp broadcast(other), do: other
end
