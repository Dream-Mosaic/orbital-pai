defmodule App.Tools.Cache do
  @moduledoc """
  A small TTL cache for tool results, backed by one `:public` named ETS table. Reads/writes hit ETS
  directly (no GenServer round-trip); this process just owns the table and sweeps expired rows.
  Stores only `{:ok, _}` results. Objects are `{key, value, expires_at_ms}` with
  `key = {session_id, name, args}`. Expiry is lazy (on read) plus a periodic sweep.
  """
  use GenServer

  @table :tool_cache
  @sweep_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @doc "Fresh cached `{:ok, result}` for `key`, or nil (evicts on expiry)."
  def get(key, now \\ now_ms()) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        value

      [{^key, _value, _expired}] ->
        :ets.delete(@table, key)
        nil

      [] ->
        nil
    end
  end

  @doc "Cache an `{:ok, _}` result for `ttl` ms. Errors and a nil ttl are ignored."
  def put(_key, {:error, _}, _ttl), do: :ok
  def put(_key, _value, nil), do: :ok

  def put(key, {:ok, _} = value, ttl) when is_integer(ttl) and ttl > 0 do
    :ets.insert(@table, {key, value, now_ms() + ttl})
    :ok
  end

  # defensive: anything else (unexpected value/ttl shape) is a no-op, never a crash.
  def put(_key, _value, _ttl), do: :ok

  @doc "Purge every entry for a tool `name` (any session/args)."
  def purge(name) do
    :ets.match_delete(@table, {{:_, name, :_}, :_, :_})
    :ok
  end

  @doc "Drop everything (tests)."
  def clear, do: :ets.delete_all_objects(@table)

  @impl true
  def handle_info(:sweep, state) do
    now = now_ms()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
