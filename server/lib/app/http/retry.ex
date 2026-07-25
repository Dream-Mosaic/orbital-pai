defmodule App.Http.Retry do
  @moduledoc """
  A Req `:retry` callback for our outbound Google calls that recovers from transient,
  *request-never-executed* failures — chiefly Finch's `:pool_not_available`.

  That error is what bites us in production: the first calendar fan-out after the node has
  been idle fires several concurrent requests at a host whose Finch pool is still starting
  lazily (a window stretched wide by the slow cold TLS connect). The racers get
  `%Finch.Error{reason: :pool_not_available}` — which Req normalizes to
  `%Req.HTTPError{protocol: :http2, reason: :pool_not_available}` (the `:http2` is a hardcoded
  Req artifact, not an HTTP/2 fact). The pool finishes coming up milliseconds later, so a
  quick retry succeeds — but the adapters had `retry: false` and gave up, failing the read.

  We retry ONLY when the failure proves the request never reached the server
  (`:pool_not_available`, http2 `:unprocessed`, `:econnrefused`, pre-send `:closed`), which
  makes it safe even for the non-idempotent POSTs (token refresh, create_event, send_email).
  Ambiguous timeouts and any server-side response (4xx/5xx) are left alone — a 5xx may have had
  a side effect, and a 4xx is a real answer.

  Wire it as `retry: &App.Http.Retry.retry?/2` (Req calls the 2-arity form with the request and
  the response-or-exception). Pair with a short `retry_delay` + small `max_retries` so a cold
  pool recovers without blowing the caller's latency budget.

  Every retry decision is logged (`[http] retrying ...`) so production can *prove* the recovery:
  the line appears, and the absence of a following `[calendar] … read failed` means the retry
  saved the call.
  """

  require Logger

  # A cold pool comes up in milliseconds, so retry fast and few — never blow the caller's
  # latency budget (calendar fetch is 6s, its fan-out task 7s). Worst case adds 2×150ms.
  @retry_delay_ms 150
  @max_retries 2

  @doc """
  Req options that enable our cold-pool retry: the predicate plus a short, bounded backoff.
  Splice into an adapter's `Req` opts, e.g. `Req.get(url, [...] ++ App.Http.Retry.opts())`.
  """
  def opts,
    do: [retry: &__MODULE__.retry?/2, retry_delay: @retry_delay_ms, max_retries: @max_retries]

  @doc "Req `:retry` predicate. True only for failures that prove the request never executed."
  def retry?(request, response_or_exception)

  # Finch couldn't hand out a connection (cold pool race) / HTTP2 stream never started — the
  # request provably did not run, so it's safe to retry regardless of method.
  def retry?(request, %Req.HTTPError{reason: reason})
      when reason in [:pool_not_available, :unprocessed],
      do: log_retry(request, reason)

  # Connection failed before the request was put on the wire.
  def retry?(request, %Req.TransportError{reason: reason})
      when reason in [:econnrefused, :closed],
      do: log_retry(request, reason)

  # Everything else (timeouts, 4xx/5xx responses, success) — do not retry.
  def retry?(_request, _response_or_exception), do: false

  defp log_retry(request, reason) do
    Logger.warning(
      "[http] retrying transient #{inspect(reason)} (request never executed) — " <>
        "#{request.method |> to_string() |> String.upcase()} #{URI.to_string(request.url)}"
    )

    true
  end
end
