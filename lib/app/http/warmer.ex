defmodule App.Http.Warmer do
  @moduledoc """
  Best-effort connection warming at boot. The deploy host pays a steep cold-connect cost on the
  first outbound call to each host (observed ~9s to first audio post-idle), which makes the very
  first tool turn blow its timeouts. We pre-open the App.Finch pools to every outbound host at
  startup so the first *user* request reuses a warm connection instead of eating that stall.

  It doubles as instrumentation: each warmup logs its connect time (`[warmup] <host> ... in Nms`),
  so production proves exactly how slow a cold connect is and which host is worst.

  Fire-and-forget: failures are logged, never fatal (a warmup HEAD that 404s still opened the
  connection, which is all we want). Runs once and exits.
  """
  use Task, restart: :transient
  require Logger

  # The outbound hosts we hit on the hot path. A few concurrent warmups per host pre-open several
  # pooled connections, so a fan-out (e.g. the multi-account calendar read) reuses warm ones.
  @hosts [
    "https://www.googleapis.com",
    "https://oauth2.googleapis.com",
    "https://gmail.googleapis.com",
    "https://generativelanguage.googleapis.com",
    "https://api.cartesia.ai"
  ]
  @conns_per_host 3
  @warm_timeout_ms 15_000

  def start_link(_opts), do: Task.start_link(__MODULE__, :run, [])

  @doc false
  def run do
    Logger.info("[warmup] opening #{@conns_per_host} conns to #{length(@hosts)} hosts")

    for host <- @hosts, _ <- 1..@conns_per_host do
      Task.Supervisor.start_child(App.Conversations.TaskSup, fn -> warm(host) end)
    end

    :ok
  end

  defp warm(host) do
    started = System.monotonic_time(:millisecond)

    result =
      Req.head(host, finch: App.Finch, retry: false, receive_timeout: @warm_timeout_ms)

    elapsed = System.monotonic_time(:millisecond) - started
    Logger.info("[warmup] #{host} #{tag(result)} in #{elapsed}ms")
  end

  defp tag({:ok, %{status: status}}), do: "ok(#{status})"
  defp tag({:error, reason}), do: "err(#{inspect(reason)})"
end
