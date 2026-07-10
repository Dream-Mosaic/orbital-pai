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
    built = for r <- refs, {:ok, pt} <- [mod.to_point(account, r)], do: {r, pt}

    items =
      for {r, pt} <- built do
        %{
          point_id: point_id(source, account.id, r.external_id),
          embed_text: pt.embed_text,
          payload: pt.payload
        }
      end

    case App.Vector.embed_and_upsert(items) do
      :ok ->
        now = DateTime.utc_now()

        for {r, pt} <- built do
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

        Logger.info("[sources] indexed #{length(built)} #{source}(s) from #{account.label}")
        :ok

      {:error, reason} ->
        Logger.warning("[sources] #{source} #{account.label} upsert failed: #{inspect(reason)}")
        :ok
    end
  end

  # ---- reconcile (only after a successful list_refs) ----

  defp reconcile(user_id, mod, account, refs) do
    source = mod.source_key()

    dropped =
      case mod.reconcile_mode() do
        :full ->
          live = MapSet.new(refs, & &1.external_id)
          Items.delete_missing(user_id, source, account.id, live)

        :age_out ->
          cutoff = DateTime.utc_now() |> DateTime.add(-max_age_days() * 86_400, :second)
          Items.prune_older_than(user_id, source, account.id, cutoff)
      end

    purge_points(source, account.id, dropped)
  end

  defp purge_points(_source, _account_id, []), do: :ok

  defp purge_points(source, account_id, external_ids) do
    ids = Enum.map(external_ids, &point_id(source, account_id, &1))

    case VectorStore.impl().delete_by_ids(ids) do
      :ok ->
        Logger.info(
          "[sources] reconciled #{length(ids)} stale #{source} point(s) from account #{account_id}"
        )

      {:error, reason} ->
        Logger.warning("[sources] reconcile purge failed: #{inspect(reason)}")
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
