defmodule App.Sources.Items do
  @moduledoc """
  Context over the `source_items` tracking table: what external items are indexed (for dedup +
  change detection), and the read-only/delete queries the Ingester + privacy purges use. The
  `missing_ids`/`older_than_ids` lookups are read-only (compute the drop set); the caller purges
  the Qdrant points for those ids FIRST, then calls `delete_external_ids/4` to drop the rows —
  so a failed purge leaves the rows in place for the next tick to retry (self-healing).
  """
  import Ecto.Query
  alias App.Repo
  alias App.Sources.Item

  @doc "Indexed items for one (user, source, account) as `%{external_id => content_hash}`."
  def refs_indexed(user_id, source, account_id) do
    from(i in Item,
      where: i.user_id == ^user_id and i.source == ^source and i.account_id == ^account_id,
      select: {i.external_id, i.content_hash}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "Upsert one item row (keyed by (user_id, source, account_id, external_id))."
  def record(attrs) do
    %Item{}
    |> Item.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:content_hash, :at, :indexed_at, :updated_at]},
      conflict_target: [:user_id, :source, :account_id, :external_id]
    )
  end

  @doc "External ids for (user, source, account) NOT in `live_ids` (read-only — does not delete)."
  def missing_ids(user_id, source, account_id, %MapSet{} = live_ids) do
    from(i in Item,
      where: i.user_id == ^user_id and i.source == ^source and i.account_id == ^account_id,
      select: i.external_id
    )
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(live_ids, &1))
  end

  @doc "External ids for (user, source, account) older than `cutoff` (read-only — does not delete)."
  def older_than_ids(user_id, source, account_id, %DateTime{} = cutoff) do
    from(i in Item,
      where:
        i.user_id == ^user_id and i.source == ^source and i.account_id == ^account_id and
          i.at < ^cutoff,
      select: i.external_id
    )
    |> Repo.all()
  end

  @doc "Delete the rows for the given external ids under (user, source, account)."
  def delete_external_ids(_user_id, _source, _account_id, []), do: :ok

  def delete_external_ids(user_id, source, account_id, external_ids) do
    Repo.delete_all(
      from i in Item,
        where:
          i.user_id == ^user_id and i.source == ^source and i.account_id == ^account_id and
            i.external_id in ^external_ids
    )

    :ok
  end

  @doc "Delete every row for one account (account disconnect)."
  def delete_for_account(user_id, account_id) do
    Repo.delete_all(from i in Item, where: i.user_id == ^user_id and i.account_id == ^account_id)

    :ok
  end

  @doc "Delete every row for one user (forget/reset)."
  def delete_for_user(user_id) do
    Repo.delete_all(from i in Item, where: i.user_id == ^user_id)
    :ok
  end
end
