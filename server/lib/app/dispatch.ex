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

  def mark_dispatched(job, %{run_id: run_id, run_number: run_number}) do
    job
    |> Ecto.Changeset.change(run_id: run_id, run_number: run_number)
    |> Repo.update()
    |> broadcast()
  end

  @doc """
  Apply a callback map (string or atom keys). Idempotent: the same status, or any status after
  an end state, is `:unchanged`. The only transition out of a running job is to an end state.
  """
  def apply_callback(%Job{} = job, attrs) do
    status = fetch(attrs, :status)

    cond do
      status == job.status -> {:ok, job, :unchanged}
      end_state?(job.status) -> {:ok, job, :unchanged}
      job.status == "running" and not end_state?(status) -> {:ok, job, :unchanged}
      true -> do_apply(job, status, attrs)
    end
  end

  defp do_apply(job, status, attrs) do
    changes =
      [status: status]
      |> Keyword.merge(
        for k <- [:branch, :pr_url, :summary, :reason],
            v = fetch(attrs, k),
            is_binary(v),
            do: {k, v}
      )

    case job |> Ecto.Changeset.change(changes) |> Repo.update() |> broadcast() do
      {:ok, job} -> {:ok, job, :changed}
      error -> error
    end
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
