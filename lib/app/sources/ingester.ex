defmodule App.Sources.Ingester do
  @moduledoc """
  Periodic external-source indexer (default every 6h, `App.Config` `source_ingest_interval_ms`). On
  each tick, for every user, for every source module, for each read-accessible account (SEQUENTIALLY),
  it diffs live `list_refs` against the `source_items` table, embeds+upserts new/changed items (capped
  per tick), records their rows only after a confirmed upsert, then reconciles vanished items
  (`:full` set-diff for Calendar / `:age_out` sweep for Gmail). Off the voice hot path; rescue-guarded
  per user; a failed item is left for the next tick (self-healing). Gated by `:start_source_ingester`.
  """
  use GenServer
  require Logger

  alias App.Sources.Items
  alias App.Google.Accounts
  alias App.Adapters.VectorStore

  # Bound each Voyage embed request so a large Gmail batch can't exceed the per-request token cap.
  @embed_max_items 96
  @embed_max_bytes 120_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    # idempotent; the collection may already exist (Embedder ensures it too).
    case VectorStore.impl().ensure_collection() do
      :ok -> Logger.info("[sources] collection ready (#{App.Config.default().qdrant_collection})")
      other -> Logger.warning("[sources] ensure_collection: #{inspect(other)}")
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

  @doc "Ingest all sources for one user (rescue-guarded; per source→account isolated)."
  def run_user(user_id) do
    for mod <- source_modules(),
        account <- Accounts.accounts_with_read(user_id, mod.connector()) do
      ingest_account(user_id, mod, account)
    end

    :ok
  rescue
    e ->
      Logger.error("[sources] user #{user_id} failed: #{inspect(e)}")
      :ok
  end

  # ---- per account ----

  defp ingest_account(user_id, mod, account) do
    source = mod.source_key()

    case mod.list_refs(account) do
      {:ok, refs} ->
        known = Items.refs_indexed(user_id, source, account.id)

        refs
        |> Enum.filter(fn r -> known[r.external_id] != r.content_hash end)
        |> Enum.take(batch())
        |> index_refs(user_id, mod, account)

        reconcile(user_id, mod, account, refs)

      {:error, reason} ->
        Logger.warning("[sources] #{source} #{account.label} list failed: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.error("[sources] #{mod.source_key()} #{account.label} crashed: #{inspect(e)}")
      :ok
  end

  defp index_refs([], _user_id, _mod, _account), do: :ok

  defp index_refs(refs, user_id, mod, account) do
    source = mod.source_key()

    for(r <- refs, {:ok, pt} <- [mod.to_point(account, r)], do: {r, pt})
    |> chunk_built()
    |> Enum.each(&upsert_and_record(&1, user_id, source, account))
  end

  # Embed + upsert one chunk, then record its source_items rows ONLY after a confirmed upsert.
  defp upsert_and_record(chunk, user_id, source, account) do
    items =
      for {r, pt} <- chunk do
        %{
          point_id: point_id(source, account.id, r.external_id),
          embed_text: pt.embed_text,
          payload: pt.payload
        }
      end

    case App.Vector.embed_and_upsert(items) do
      :ok ->
        now = DateTime.utc_now()

        for {r, pt} <- chunk do
          Items.record(%{
            user_id: user_id,
            account_id: account.id,
            source: source,
            external_id: r.external_id,
            content_hash: r.content_hash,
            at: pt.at,
            indexed_at: now
          })
        end

        Logger.info("[sources] indexed #{length(chunk)} #{source}(s) from #{account.label}")

      {:error, reason} ->
        Logger.warning("[sources] #{source} #{account.label} upsert failed: #{inspect(reason)}")
    end
  end

  # Split built {ref, point} pairs into sub-batches, each within @embed_max_items and @embed_max_bytes,
  # so no single Voyage request is oversized. A single item larger than the byte budget still ships alone.
  defp chunk_built(built) do
    {chunks, cur, _n, _bytes} =
      Enum.reduce(built, {[], [], 0, 0}, fn {_r, pt} = item, {chunks, cur, n, bytes} ->
        sz = byte_size(pt.embed_text)

        if cur != [] and (n + 1 > @embed_max_items or bytes + sz > @embed_max_bytes) do
          {[Enum.reverse(cur) | chunks], [item], 1, sz}
        else
          {chunks, [item | cur], n + 1, bytes + sz}
        end
      end)

    chunks = if cur == [], do: chunks, else: [Enum.reverse(cur) | chunks]
    Enum.reverse(chunks)
  end

  # ---- reconcile (only after a successful list_refs). Purge Qdrant points FIRST, then delete the
  # source_items rows only on a confirmed purge, so a transient Qdrant failure leaves the rows in
  # place and the next tick recomputes the same drop set and retries (self-healing; no orphans). ----

  defp reconcile(user_id, mod, account, refs) do
    source = mod.source_key()

    dropped =
      case mod.reconcile_mode() do
        :full ->
          Items.missing_ids(user_id, source, account.id, MapSet.new(refs, & &1.external_id))

        :age_out ->
          cutoff = DateTime.utc_now() |> DateTime.add(-max_age_days() * 86_400, :second)
          Items.older_than_ids(user_id, source, account.id, cutoff)
      end

    purge_dropped(user_id, source, account, dropped)
  end

  defp purge_dropped(_user_id, _source, _account, []), do: :ok

  defp purge_dropped(user_id, source, account, external_ids) do
    point_ids = Enum.map(external_ids, &point_id(source, account.id, &1))

    case VectorStore.impl().delete_by_ids(point_ids) do
      :ok ->
        Items.delete_external_ids(user_id, source, account.id, external_ids)

        Logger.info(
          "[sources] reconciled #{length(external_ids)} stale #{source} point(s) from account #{account.id}"
        )

      {:error, reason} ->
        Logger.warning(
          "[sources] #{source} reconcile purge failed (rows kept for retry): #{inspect(reason)}"
        )
    end
  end

  # ---- helpers ----

  defp source_modules,
    do: Application.get_env(:app, :source_modules, [App.Sources.Gmail, App.Sources.Calendar])

  defp batch,
    do:
      Application.get_env(:app, :source_ingest_batch_override) ||
        App.Config.default().source_ingest_batch

  defp max_age_days, do: App.Config.default().gmail_index_max_age_days

  defp point_id(source, account_id, external_id),
    do: App.Adapters.VectorStore.Qdrant.point_id(source, "#{account_id}:#{external_id}")

  defp schedule,
    do: Process.send_after(self(), :tick, App.Config.default().source_ingest_interval_ms)
end
