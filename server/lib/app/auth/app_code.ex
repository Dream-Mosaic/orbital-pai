defmodule App.Auth.AppCode do
  @moduledoc """
  One-time, short-lived codes that stand in for a `Phoenix.Token` across the app's
  `orbital://auth?code=…` deep link.

  A `Phoenix.Token` minted by `AppWeb.UserAuth.socket_token/1` is a 30-day credential. Putting
  it directly in a deep-link URL means it lands in the browser's history, in Android's intent
  logs, and in the hands of any other app that also registered the `orbital` scheme. This module
  mints a code instead: it is worthless 60 seconds after minting and worthless after the first
  exchange, so capturing it later (from history, from logs, from a nosy app) buys an attacker
  nothing. The app exchanges the code for the real token over a direct HTTPS POST
  (`POST /api/auth/exchange`), which never touches a URL bar or a log line the way a deep link
  does. This is the OAuth authorization-code pattern applied one layer down, for the same reason
  it exists one layer up.

  Storage is an in-memory map on this GenServer: `%{code => {user_id, expires_at}}`. That's
  correct for something that lives seconds — losing every outstanding code on a restart costs at
  most one re-login, nothing more.

  `exchange/2` is a single `handle_call` that pops the entry AND checks expiry in one message,
  handled inside this process. A read followed by a separate delete would let two concurrent
  exchanges both observe the code as present and both succeed — the single-use guarantee is the
  entire security property here, so it cannot be split across two messages. Expiry is checked
  again on every read (not just relied on from the sweep) because the periodic prune
  (`Process.send_after/3`) only runs every `ttl_ms`; without the read-time check, a code that
  expired between sweeps would still exchange successfully.
  """

  use GenServer

  @default_ttl_ms 60_000

  ## Client API

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Mint a fresh single-use code for `user_id`, valid for this server's TTL."
  def mint(server \\ __MODULE__, user_id) do
    GenServer.call(server, {:mint, user_id})
  end

  @doc "Atomically pop and validate `code`. Returns `{:ok, user_id}` at most once per code."
  def exchange(server \\ __MODULE__, code) do
    GenServer.call(server, {:exchange, code})
  end

  ## Server callbacks

  @impl true
  def init(opts) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    schedule_prune(ttl_ms)
    {:ok, %{codes: %{}, ttl_ms: ttl_ms}}
  end

  @impl true
  def handle_call({:mint, user_id}, _from, %{codes: codes, ttl_ms: ttl_ms} = state) do
    code = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    {:reply, code, %{state | codes: Map.put(codes, code, {user_id, expires_at})}}
  end

  def handle_call({:exchange, code}, _from, %{codes: codes} = state) do
    now = System.monotonic_time(:millisecond)

    case Map.pop(codes, code) do
      {{user_id, expires_at}, remaining} when expires_at > now ->
        {:reply, {:ok, user_id}, %{state | codes: remaining}}

      {nil, _remaining} ->
        {:reply, {:error, :invalid}, state}

      {{_user_id, _expires_at}, remaining} ->
        # Already popped (and thus already consumed) even though it was expired -- there is no
        # reason to leave a dead entry sitting in the map until the next sweep.
        {:reply, {:error, :invalid}, %{state | codes: remaining}}
    end
  end

  @impl true
  def handle_info(:prune, %{codes: codes, ttl_ms: ttl_ms} = state) do
    now = System.monotonic_time(:millisecond)
    live = for {code, {_uid, exp} = v} <- codes, exp > now, into: %{}, do: {code, v}
    schedule_prune(ttl_ms)
    {:noreply, %{state | codes: live}}
  end

  defp schedule_prune(ttl_ms), do: Process.send_after(self(), :prune, ttl_ms)
end
