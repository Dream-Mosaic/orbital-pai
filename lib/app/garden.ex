defmodule App.Garden do
  @moduledoc """
  The garden book: plants + check-in notes — persistence, queries, and the notify seam
  (parallels `App.Lists`). Mutations broadcast `{:garden_changed}` on `"garden:<user_id>"`
  so the LiveView panel stays live; household (shared) rows also notify `"garden:household"`
  so every member's panel updates. Archived plants are kept as history, grouped by season.
  """
  import Ecto.Query
  alias App.Repo
  alias App.Garden.{Plant, Note}

  @doc """
  Create an active plant for the resolved owner. `owner` is a `%{user_id, household}` map
  (e.g. from `App.Garden.Target.resolve/2`); `attrs` is ATOM-keyed and carries `name`
  (required) plus whatever optional fields were mentioned (`species`, `location`, `count`,
  `planted_on`). Always inserts `status: "active"` — a replant next year is a fresh plant.
  """
  def add_plant(%{user_id: uid, household: household}, attrs) do
    case %Plant{}
         |> Plant.changeset(
           Map.merge(attrs, %{user_id: uid, household: household, status: "active"})
         )
         |> Repo.insert() do
      {:ok, plant} ->
        broadcast_changed(plant.user_id, plant.household)
        {:ok, plant}

      other ->
        other
    end
  end

  @doc """
  Everything `user_id` can see (own + household), split by lifecycle:
  `%{active: [plants], archived_by_season: %{"2026" => [plants], ...}}` — each plant
  preloaded with its notes (oldest first), active plants oldest-first. A nil `season`
  falls back to the year of `archived_at`. Backs the kiosk panel and the read tool.
  """
  def garden(user_id) do
    plants =
      Plant
      |> where([p], p.user_id == ^user_id or p.household == true)
      |> order_by([p], asc: p.inserted_at, asc: p.id)
      |> preload(notes: ^notes_query())
      |> Repo.all()

    {active, archived} = Enum.split_with(plants, &(&1.status == "active"))
    %{active: active, archived_by_season: Enum.group_by(archived, &season_of/1)}
  end

  @doc false
  def season_of(%Plant{season: s}) when is_binary(s) and s != "", do: s
  def season_of(%Plant{archived_at: %DateTime{year: y}}), do: Integer.to_string(y)
  def season_of(_plant), do: "past"

  defp notes_query, do: from(n in Note, order_by: [asc: n.inserted_at, asc: n.id])

  @doc """
  The best-matching plant in `user_id`'s VISIBLE set (own + household) for a spoken phrase —
  case-insensitive contains either way (like `Lists.find_item`), against the NAME or the
  SPECIES. An ACTIVE plant wins over an archived namesake (same-named plants across seasons
  are history, not collisions — "the tomatoes" means this year's). nil when nothing matches.
  """
  def find_plant(user_id, phrase) when is_binary(phrase) do
    p = phrase |> String.downcase() |> String.trim()

    if p == "" do
      nil
    else
      Plant
      |> where([q], q.user_id == ^user_id or q.household == true)
      |> Repo.all()
      |> Enum.filter(fn plant ->
        Enum.any?([plant.name, plant.species], fn field ->
          t = String.downcase(field || "")
          t != "" and (String.contains?(t, p) or String.contains?(p, t))
        end)
      end)
      |> Enum.sort_by(&(&1.status != "active"))
      |> Enum.at(0)
    end
  end

  def find_plant(_user_id, _phrase), do: nil

  @doc """
  Retire one plant: `status` → "archived", stamp `archived_at` + `season` (the given one, or
  the current year). Archiving an already-archived plant is a benign `{:noop, plant}` — the
  voice tool narrates it instead of double-stamping. Broadcasts.
  """
  def archive_plant(plant, season \\ nil)
  def archive_plant(%Plant{status: "archived"} = plant, _season), do: {:noop, plant}

  def archive_plant(%Plant{} = plant, season) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case plant
         |> Plant.changeset(%{
           status: "archived",
           season: season || Integer.to_string(now.year),
           archived_at: now
         })
         |> Repo.update() do
      {:ok, archived} ->
        broadcast_changed(archived.user_id, archived.household)
        {:ok, archived}

      other ->
        other
    end
  end

  @doc """
  Season close-out: bulk-archive every ACTIVE plant in the owner scope (household owner →
  the household garden; personal owner → that user's own personal plants — same scoping as
  `Lists.find_or_create_list/2`). Returns the count archived. One broadcast.
  """
  def close_season(%{user_id: uid, household: household}, season \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    season = season || Integer.to_string(now.year)

    {count, _} =
      Plant
      |> where([p], p.status == "active")
      |> owner_scope(uid, household)
      |> Repo.update_all(
        set: [status: "archived", season: season, archived_at: now, updated_at: now]
      )

    broadcast_changed(uid, household)
    count
  end

  defp owner_scope(query, _uid, true), do: where(query, [p], p.household == true)

  defp owner_scope(query, uid, false),
    do: where(query, [p], p.household == false and p.user_id == ^uid)

  @doc "Append a check-in note to `plant`. `noted_on` is an optional `Date` (nil = undated). Broadcasts."
  def add_note(%Plant{} = plant, body, noted_on \\ nil) do
    case %Note{}
         |> Note.changeset(%{plant_id: plant.id, body: body, noted_on: noted_on})
         |> Repo.insert() do
      {:ok, note} ->
        broadcast_changed(plant.user_id, plant.household)
        {:ok, note}

      other ->
        other
    end
  end

  @doc "Bring an archived plant back: status → active, season/archived_at cleared. Broadcasts."
  def revive_plant(%Plant{} = plant) do
    case plant
         |> Plant.changeset(%{status: "active", season: nil, archived_at: nil})
         |> Repo.update() do
      {:ok, revived} ->
        broadcast_changed(revived.user_id, revived.household)
        {:ok, revived}

      other ->
        other
    end
  end

  @doc "Rename a plant. Broadcasts."
  def rename_plant(%Plant{} = plant, name) do
    case plant |> Plant.changeset(%{name: name}) |> Repo.update() do
      {:ok, renamed} ->
        broadcast_changed(renamed.user_id, renamed.household)
        {:ok, renamed}

      other ->
        other
    end
  end

  @doc "Hard delete (notes cascade). For mistakes — archiving is the normal retirement. Broadcasts."
  def remove_plant(%Plant{} = plant) do
    case Repo.delete(plant) do
      {:ok, deleted} ->
        broadcast_changed(deleted.user_id, deleted.household)
        {:ok, deleted}

      other ->
        other
    end
  end

  @doc "Tell subscribers the garden changed. Household rows also notify every member's panel."
  def broadcast_changed(user_id) do
    Phoenix.PubSub.broadcast(App.PubSub, "garden:#{user_id}", {:garden_changed})
  end

  def broadcast_changed(user_id, true) do
    broadcast_changed(user_id)
    Phoenix.PubSub.broadcast(App.PubSub, "garden:household", {:garden_changed})
  end

  def broadcast_changed(user_id, false), do: broadcast_changed(user_id)
end
