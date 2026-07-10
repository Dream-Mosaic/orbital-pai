defmodule App.Sources.Items do
  @moduledoc """
  Context over the `source_items` tracking table: what external items are indexed (for dedup +
  change detection), and the prune/delete queries the Ingester + privacy purges use. The prune
  helpers return the dropped `external_id`s so the caller can purge their Qdrant points.
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

  @doc "Delete rows for (user, source, account) whose external_id is NOT in `live_ids`. Returns dropped ids."
  def delete_missing(user_id, source, account_id, %MapSet{} = live_ids) do
    rows =
      from(i in Item,
        where: i.user_id == ^user_id and i.source == ^source and i.account_id == ^account_id,
        select: {i.id, i.external_id}
      )
      |> Repo.all()

    dropped = for {id, ext} <- rows, not MapSet.member?(live_ids, ext), do: {id, ext}
    delete_ids(Enum.map(dropped, &elem(&1, 0)))
    Enum.map(dropped, &elem(&1, 1))
  end

  @doc "Delete rows for (user, source, account) older than `cutoff`. Returns dropped ids."
  def prune_older_than(user_id, source, account_id, %DateTime{} = cutoff) do
    rows =
      from(i in Item,
        where:
          i.user_id == ^user_id and i.source == ^source and i.account_id == ^account_id and
            i.at < ^cutoff,
        select: {i.id, i.external_id}
      )
      |> Repo.all()

    delete_ids(Enum.map(rows, &elem(&1, 0)))
    Enum.map(rows, &elem(&1, 1))
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

  defp delete_ids([]), do: :ok
  defp delete_ids(ids), do: Repo.delete_all(from i in Item, where: i.id in ^ids)
end
