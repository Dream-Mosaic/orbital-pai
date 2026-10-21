defmodule App.Dispatch.Watchdog do
  @moduledoc """
  Catches dispatch jobs that never report back. Every 5 minutes, for each `queued`/`running`
  job: if the forge says its run finished (status success/failure/cancelled/skipped, or `stopped` set) and the job is >= 10 min old and the run stopped >= 3 min ago (grace for an in-flight callback), the job ended without calling back (`failed`). A run still waiting/running is left alone
  whatever its age (the box runs one job at a time, so queueing for hours is legitimate); a run the forge no longer knows (404) is `lost`; if every read errors for 24 h it is `lost`; a job with no `run_id` is `lost` after 6 h of silence. Status changes go ONLY through `Dispatch.set_status/3`
  (race-safe: a no-op if a real callback landed first), then the job is handed to the notifier,
  whose `notified_at` claim keeps a double path from notifying twice. `tick/1` takes an
  injectable `now` so tests drive it directly.

  It also warms the repos toolkit's repo names once, 10 seconds after boot
  (`App.Dispatch.Board.warm/0`, in a task), so a repo's name preselects the kit from the first
  turn.
  """
  use GenServer
  require Logger

  alias App.Dispatch
  alias App.Dispatch.{Forge, Notifier}

  @interval_ms 5 * 60_000
  # The one-shot read of the repo names, a little after boot (never blocks it).
  @warm_after_ms 10_000
  @no_run_ms 6 * 3_600_000
  @blind_ms 24 * 3_600_000
  @min_age_ms 10 * 60_000
  @grace_ms 3 * 60_000
  @finished ~w(success failure cancelled skipped)
  @silent_reason "the job ended without reporting back"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    Process.send_after(self(), :tick, @interval_ms)
    Process.send_after(self(), :warm, @warm_after_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      tick()
    rescue
      e -> Logger.warning("dispatch watchdog tick failed: #{Exception.message(e)}")
    end

    Process.send_after(self(), :tick, @interval_ms)
    {:noreply, state}
  end

  # Off this process: a slow or absent forge must not hold up the ticks.
  def handle_info(:warm, state) do
    Task.Supervisor.start_child(App.Conversations.TaskSup, &App.Dispatch.Board.warm/0)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  def tick(now \\ DateTime.utc_now()) do
    for job <- Dispatch.stale_jobs(now, @min_age_ms), do: check(job, now)
    :ok
  end

  # Age alone never marks a job lost: the box runs ONE job at a time, so a legitimately queued
  # run can wait hours in the forge's queue. The run's own state decides.
  defp check(%{run_id: id} = job, now) when is_integer(id) do
    case Forge.run(id) do
      {:ok, %{status: status, stopped: stopped}} ->
        if finished?(status, stopped) and
             (is_nil(stopped) or DateTime.diff(now, stopped, :millisecond) >= @grace_ms),
           do: finish(job, "failed", @silent_reason)

      {:error, :not_found} ->
        finish(job, "lost", "the run disappeared")

      _ ->
        if older_than?(job, now, @blind_ms),
          do: finish(job, "lost", "couldn't check on the run")
    end
  end

  # No run info (accepted without it, or uncertain): only a long silence counts as lost.
  defp check(job, now) do
    if older_than?(job, now, @no_run_ms), do: finish(job, "lost", "never heard from the run")
  end

  defp older_than?(job, now, ms) do
    DateTime.diff(now, DateTime.from_naive!(to_naive(job.inserted_at), "Etc/UTC"), :millisecond) >=
      ms
  end

  defp to_naive(%DateTime{} = dt), do: DateTime.to_naive(dt)
  defp to_naive(%NaiveDateTime{} = n), do: n

  defp finished?(status, stopped), do: status in @finished or not is_nil(stopped)

  defp finish(job, status, reason) do
    case Dispatch.set_status(job, status, reason) do
      {:ok, j, :changed} -> Notifier.notify(j)
      _ -> :ok
    end
  end
end
