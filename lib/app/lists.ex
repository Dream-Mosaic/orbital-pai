defmodule App.Lists do
  @moduledoc """
  Lists ("books"): create-on-demand persistence + queries, plus a notify seam — add/check/
  uncheck/clear/remove broadcast `{:lists_changed}` on `"lists:<user_id>"` so the LiveView panel
  stays live (same pattern as `App.Reminders`). Household (shared) rows also notify
  `"lists:household"` so every member's panel updates.
  """
  import Ecto.Query
  alias App.Repo
  alias App.Lists.{List, Item}

  @doc """
  The list matching `name` (case-insensitive) in `owner`'s VISIBLE set (own rows + household
  rows); creates it (with the resolved `user_id`/`household`) if absent. A household match wins
  over a personal one when both exist (shared-default) — this is how "add milk to groceries"
  lands on THE groceries book regardless of who's asking. `owner` is a `%{user_id, household}`
  map (e.g. from `App.Lists.Target.resolve/2`).
  """
  def find_or_create_list(%{user_id: uid, household: household}, name) do
    down = String.downcase(name)

    matches =
      List
      |> where([l], l.user_id == ^uid or l.household == true)
      |> Repo.all()
      |> Enum.filter(&(String.downcase(&1.name) == down))

    case Enum.find(matches, & &1.household) || Enum.at(matches, 0) do
      nil ->
        {:ok, list} =
          %List{}
          |> List.changeset(%{user_id: uid, household: household, name: name})
          |> Repo.insert()

        list

      list ->
        list
    end
  end

  @doc "Every list `user_id` can see (own + household), each preloaded with its items, oldest first."
  def list_visible(user_id) do
    List
    |> where([l], l.user_id == ^user_id or l.household == true)
    |> order_by([l], asc: l.name)
    |> preload(items: ^items_query())
    |> Repo.all()
  end

  @doc "Reload `list` with its items preloaded, oldest first (used by the read tool)."
  def with_items(%List{} = list), do: Repo.preload(list, [items: items_query()], force: true)

  defp items_query, do: from(i in Item, order_by: [asc: i.inserted_at, asc: i.id])

  def add_item(%List{} = list, text) do
    case %Item{} |> Item.changeset(%{list_id: list.id, text: text}) |> Repo.insert() do
      {:ok, item} ->
        broadcast_changed(list.user_id, list.household)
        {:ok, item}

      other ->
        other
    end
  end

  @doc "Stamp `checked_at` (checked off)."
  def check_item(%Item{} = item),
    do: stamp(item, DateTime.utc_now() |> DateTime.truncate(:second))

  @doc "Clear `checked_at` (back to pending)."
  def uncheck_item(%Item{} = item), do: stamp(item, nil)

  defp stamp(item, value) do
    item = Repo.preload(item, :list)

    case item |> Item.changeset(%{checked_at: value}) |> Repo.update() do
      {:ok, updated} ->
        broadcast_changed(item.list.user_id, item.list.household)
        {:ok, updated}

      other ->
        other
    end
  end

  @doc "Delete the done (checked) items on a list; returns the count removed."
  def clear_checked(%List{} = list) do
    {count, _} =
      Item
      |> where([i], i.list_id == ^list.id and not is_nil(i.checked_at))
      |> Repo.delete_all()

    broadcast_changed(list.user_id, list.household)
    count
  end

  def remove_item(%Item{} = item) do
    item = Repo.preload(item, :list)

    case Repo.delete(item) do
      {:ok, deleted} ->
        broadcast_changed(item.list.user_id, item.list.household)
        {:ok, deleted}

      other ->
        other
    end
  end

  def delete_list(%List{} = list) do
    case Repo.delete(list) do
      {:ok, deleted} ->
        broadcast_changed(deleted.user_id, deleted.household)
        {:ok, deleted}

      other ->
        other
    end
  end

  @doc """
  The best-matching item in `list` for a spoken phrase — case-insensitive contains either way
  (like `Reminders.find_pending`); an unchecked item wins over an already-checked one so "check
  off the milk" finds the pending one, not a stale duplicate. nil when nothing matches.
  """
  def find_item(%List{} = list, phrase) when is_binary(phrase) do
    p = phrase |> String.downcase() |> String.trim()

    if p == "" do
      nil
    else
      list = Repo.preload(list, :items)

      list.items
      |> Enum.filter(fn i ->
        t = String.downcase(i.text)
        String.contains?(t, p) or String.contains?(p, t)
      end)
      |> Enum.sort_by(&(&1.checked_at != nil))
      |> Enum.at(0)
    end
  end

  def find_item(_list, _phrase), do: nil

  @doc "Tell subscribers the list set changed. Household rows also notify every member's panel."
  def broadcast_changed(user_id) do
    Phoenix.PubSub.broadcast(App.PubSub, "lists:#{user_id}", {:lists_changed})
  end

  def broadcast_changed(user_id, true) do
    broadcast_changed(user_id)
    Phoenix.PubSub.broadcast(App.PubSub, "lists:household", {:lists_changed})
  end

  def broadcast_changed(user_id, false), do: broadcast_changed(user_id)
end
