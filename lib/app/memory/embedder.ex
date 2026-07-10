defmodule App.Memory.Embedder do
  @moduledoc """
  Periodic semantic indexer. On each tick (default every 4h, `App.Config` `embed_interval_ms`), for
  every user, batch-embed turns+digests with `embedded_at IS NULL` (Voyage), upsert to the vector
  store (Qdrant), stamp `embedded_at`. Off the voice hot path; rescue-guarded per user; failures
  leave rows unembedded for the next tick (self-healing). Existing rows backfill over the first
  ticks. Gated by `:start_memory_embedder`, like the Consolidator.
  """
  use GenServer
  require Logger

  alias App.Memory

  @batch 128

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    # Best-effort: a Qdrant that isn't up yet must not crash the supervisor.
    case App.Adapters.VectorStore.impl().ensure_collection() do
      :ok -> :ok
      other -> Logger.warning("[embedder] ensure_collection: #{inspect(other)}")
    end

    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    for user <- App.Users.list(), do: run_user(user.id)
    schedule()
    {:noreply, state}
  end

  @doc "Embed one user's unembedded turns + digests (idempotent; rescue-guarded)."
  def run_user(user_id) do
    index(user_id, :turn, Memory.unembedded_turns(user_id, @batch), &Memory.embed_text_for/1)
    index(user_id, :digest, Memory.unembedded_digests(user_id, @batch), & &1.content)
    :ok
  rescue
    e ->
      Logger.error("[embedder] user #{user_id} failed: #{inspect(e)}")
      :ok
  end

  defp index(_user_id, _source, [], _text_fun), do: :ok

  # Embed the batch, upsert points, THEN stamp — stamp only after a confirmed upsert (cost control +
  # idempotency). Any failure aborts this batch, leaving rows for the next tick.
  defp index(user_id, source, rows, text_fun) do
    texts = Enum.map(rows, text_fun)

    with {:ok, vectors} <- App.Adapters.Embeddings.impl().embed(texts, :document),
         points = build_points(user_id, source, rows, vectors, text_fun),
         :ok <- App.Adapters.VectorStore.impl().upsert(points) do
      Memory.mark_embedded(source, Enum.map(rows, & &1.id))
    else
      other ->
        Logger.warning(
          "[embedder] #{source} batch for user #{user_id} not indexed: #{inspect(other)}"
        )

        :ok
    end
  end

  defp build_points(user_id, source, rows, vectors, text_fun) do
    src = to_string(source)

    rows
    |> Enum.zip(vectors)
    |> Enum.map(fn {row, vector} ->
      %{
        id: App.Adapters.VectorStore.Qdrant.point_id(src, row.id),
        vector: vector,
        payload: %{
          user_id: user_id,
          source: src,
          source_id: row.id,
          text: text_fun.(row),
          at: at_of(row)
        }
      }
    end)
  end

  defp at_of(%App.Memory.Turn{inserted_at: at}), do: to_string(at)
  defp at_of(%App.Memory.Digest{date: date}), do: to_string(date)

  defp schedule, do: Process.send_after(self(), :tick, App.Config.default().embed_interval_ms)
end
