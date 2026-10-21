defmodule App.Dispatch.Watchdog do
  @moduledoc """
  Catches dispatch jobs that never report back. Every 5 minutes, for each `queued`/`running`
  job: if the forge says its run finished (status success/failure/cancelled/skipped, or `stopped` set) and the job is >= 10 min old and the run stopped >= 3 min ago (grace for an in-flight callback), the job ended without calling back (`failed`); if it
  is older than 130 minutes, it is `lost`. Status changes go ONLY through `Dispatch.set_status/3`
  (race-safe: a no-op if a real callback landed first), then the job is handed to the notifier,
  whose `notified_at` claim keeps a double path from notifying twice. `tick/1` takes an
  injectable `now` so tests drive it directly.
  """
  use GenServer
  require Logger

  alias App.Dispatch
  alias App.Dispatch.{Forge, Notifier}

  @interval_ms 5 * 60_000
  @max_age_ms 130 * 60_000
  @min_age_ms 10 * 60_000
  @grace_ms 3 * 60_000
  @finished ~w(success failure cancelled skipped)
  @silent_reason "the job ended without reporting back"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    Process.send_after(self(), :tick, @interval_ms)
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

  def handle_info(_, state), do: {:noreply, state}

  def tick(now \\ DateTime.utc_now()) do
    old = MapSet.new(Dispatch.stale_jobs(now, @max_age_ms), & &1.id)

    for job <- Dispatch.stale_jobs(now, @min_age_ms) do
      cond do
        silently_ended?(job, now) -> finish(job, "failed", @silent_reason)
        MapSet.member?(old, job.id) -> finish(job, "lost", "no report within 130 minutes")
        true -> :ok
      end
    end

    :ok
  end

  # The run is over AND its callback had a fair chance to land (stopped >= 3 min ago, or unknown).
  defp silently_ended?(%{run_id: id}, now) when is_integer(id) do
    case Forge.run(id) do
      {:ok, %{status: status, stopped: stopped}} ->
        finished?(status, stopped) and
          (is_nil(stopped) or DateTime.diff(now, stopped, :millisecond) >= @grace_ms)

      _ ->
        false
    end
  end

  defp silently_ended?(_, _), do: false

  defp finished?(status, stopped), do: status in @finished or not is_nil(stopped)

  defp finish(job, status, reason) do
    case Dispatch.set_status(job, status, reason) do
      {:ok, j, :changed} -> Notifier.notify(j)
      _ -> :ok
    end
  end
end
