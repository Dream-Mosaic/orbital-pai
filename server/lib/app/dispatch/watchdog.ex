defmodule App.Dispatch.Watchdog do
  @moduledoc """
  Catches dispatch jobs that never report back. Every 5 minutes it checks each `queued`/
  `running` job older than 10 minutes. Age alone never marks a job lost: the box runs one job
  at a time, so a run can legitimately wait hours in the forge's queue. The rules:

    * With a `run_id`, the forge's run decides. A run that finished (status success/failure/
      cancelled/skipped, or `stopped` set) at least 3 minutes ago (grace for an in-flight
      callback) means the job ended without calling back: `failed`, "check the issue for a
      PR" (a lost callback or a wrong secret looks just like this). A run still waiting or
      running is left alone. A run the forge no longer knows (404) is `lost`.
    * Read errors: the first failed read of a streak is stamped on the job
      (`read_error_since`, cleared by the next good read), and only 24 h of failed reads in a
      row mark it `lost`. A restart doesn't reset the streak.
    * Without a `run_id`, nothing can be read. A `queued` job is `lost` 6 h after it was
      created. A `running` job proved itself alive, so its 6 h count from its last callback
      (`updated_at`).

  Status changes go ONLY through `Dispatch.set_status/3` (race-safe: a no-op if a real callback
  landed first), then the job is handed to the notifier, whose `notified_at` claim keeps a
  double path from notifying twice. `tick/1` takes an injectable `now` so tests drive it.

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
  # A lost callback or a mismatched secret looks exactly like this, and the PR may well exist.
  @silent_reason "the job ended without reporting back — check the issue for a PR"
  @quiet_reason "it started but never reported back — check the issue for a PR"

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

  defp check(%{run_id: id} = job, now) when is_integer(id) do
    case Forge.run(id) do
      {:ok, %{status: status, stopped: stopped}} ->
        Dispatch.clear_read_error(job)

        if finished?(status, stopped) and
             (is_nil(stopped) or DateTime.diff(now, stopped, :millisecond) >= @grace_ms),
           do: finish(job, "failed", @silent_reason)

      {:error, :not_found} ->
        finish(job, "lost", "the run disappeared")

      _ ->
        read_failed(job, now)
    end
  end

  # No run info (accepted without it, or uncertain): only a long silence counts as lost. A
  # running job has called back, so its silence counts from that callback.
  defp check(%{status: "running"} = job, now) do
    if since?(job.updated_at, now, @no_run_ms), do: finish(job, "lost", @quiet_reason)
  end

  defp check(job, now) do
    if since?(job.inserted_at, now, @no_run_ms),
      do: finish(job, "lost", "never heard from the run")
  end

  # The streak's start lives on the row, so a restart doesn't reset it.
  defp read_failed(%{read_error_since: nil} = job, now), do: Dispatch.note_read_error(job, now)

  defp read_failed(%{read_error_since: first} = job, now) do
    if since?(first, now, @blind_ms), do: finish(job, "lost", "couldn't check on the run")
  end

  defp since?(at, now, ms),
    do: DateTime.diff(now, DateTime.from_naive!(to_naive(at), "Etc/UTC"), :millisecond) >= ms

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
