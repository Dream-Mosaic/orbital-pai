defmodule App.Http.RetryTest do
  use ExUnit.Case, async: true

  alias App.Http.Retry

  # The request struct Req hands the callback; only :method is inspected.
  defp post, do: %Req.Request{method: :post}
  defp get, do: %Req.Request{method: :get}

  describe "request-never-executed errors retry for ANY method" do
    test "pool_not_available (cold Finch pool race) — the bug we're fixing" do
      err = %Req.HTTPError{protocol: :http2, reason: :pool_not_available}
      assert Retry.retry?(post(), err)
      assert Retry.retry?(get(), err)
    end

    test "http2 :unprocessed (stream provably never ran)" do
      err = %Req.HTTPError{protocol: :http2, reason: :unprocessed}
      assert Retry.retry?(post(), err)
    end

    test "connection refused / closed before the request was sent" do
      assert Retry.retry?(post(), %Req.TransportError{reason: :econnrefused})
      assert Retry.retry?(post(), %Req.TransportError{reason: :closed})
    end
  end

  describe "opts/0" do
    test "wires the predicate plus a short, bounded backoff" do
      opts = Retry.opts()
      assert opts[:retry] == (&Retry.retry?/2)
      assert is_integer(opts[:retry_delay]) and opts[:retry_delay] <= 500
      assert opts[:max_retries] in 1..3
    end
  end

  describe "ambiguous or server-side outcomes do NOT retry" do
    test ":timeout is ambiguous (request may have reached the server) — no retry" do
      refute Retry.retry?(post(), %Req.TransportError{reason: :timeout})
    end

    test "a 5xx response reached the server — never retry (could double-create)" do
      refute Retry.retry?(get(), %Req.Response{status: 503})
      refute Retry.retry?(post(), %Req.Response{status: 500})
    end

    test "a 4xx is a real answer — no retry" do
      refute Retry.retry?(get(), %Req.Response{status: 400})
      refute Retry.retry?(get(), %Req.Response{status: 404})
    end

    test "a successful response never retries" do
      refute Retry.retry?(get(), %Req.Response{status: 200})
    end
  end
end
