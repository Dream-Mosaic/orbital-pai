defmodule App.Memory do
  @moduledoc """
  The "remembers me" layer: durable profile facts + a rolling summary + recent turns.
  Read path (`context/1`) is bounded and does no model call; the model-driven update
  lives in `App.Memory.Updater`.
  """
  import Ecto.Query
  alias App.Repo
  alias App.Memory.{Turn, ProfileFact, Summary, Digest}

  @recent_turns 8
  @max_auto_facts 30
  @pubsub_topic "memory"

  # ---- live updates: let the UI reflect model-driven memory changes ----
  @doc "Subscribe the calling process to memory-change notifications."
  def subscribe, do: Phoenix.PubSub.subscribe(App.PubSub, @pubsub_topic)

  @doc "Notify subscribers (e.g. the LiveView) that memory changed."
  def broadcast_updated,
    do: Phoenix.PubSub.broadcast(App.PubSub, @pubsub_topic, :memory_updated)

  # ---- turns ----
  def persist_turn(attrs) do
    %Turn{} |> Turn.changeset(attrs) |> Repo.insert()
  end

  def recent_turns(user_id, limit \\ @recent_turns) do
    Turn
    |> where([t], t.user_id == ^user_id)
    |> order_by([t], desc: t.inserted_at, desc: t.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  # ---- the bounded context injected into the brain each turn ----
  def context(session_id, opts \\ []) do
    case App.Users.id_from_session(session_id) do
      nil ->
        %{profile: "", summary: "", recent: [], user_name: nil}

      user_id ->
        facts = list_facts(user_id)
        recent = if Keyword.get(opts, :recent, true), do: recent_turns(user_id), else: []
        user = Repo.get(App.Users.User, user_id)

        %{
          profile: facts |> Enum.map(&fact_line/1) |> Enum.join("\n"),
          summary: get_summary(user_id).content,
          recent: recent,
          user_name: user && user.name
        }
    end
  end

  defp fact_line(%ProfileFact{category: nil, content: c}), do: "- #{c}"
  defp fact_line(%ProfileFact{category: cat, content: c}), do: "- (#{cat}) #{c}"

  # ---- facts (transparent + editable; LiveView CRUD) ----
  def list_facts(user_id) do
    ProfileFact
    |> where([f], f.user_id == ^user_id)
    |> order_by([f], asc: f.inserted_at, asc: f.id)
    |> Repo.all()
  end

  def get_fact(id), do: Repo.get(ProfileFact, id)

  def create_fact(attrs), do: %ProfileFact{} |> ProfileFact.changeset(attrs) |> Repo.insert()

  def update_fact(%ProfileFact{} = f, attrs),
    do: f |> ProfileFact.changeset(attrs) |> Repo.update()

  def delete_fact(%ProfileFact{} = f), do: Repo.delete(f)

  @doc "Cap a user's auto-facts to the most recent `keep`; never touches source == \"user\"."
  def prune_auto_facts(user_id, keep \\ @max_auto_facts) do
    ProfileFact
    |> where([f], f.user_id == ^user_id and f.source == "auto")
    |> order_by([f], desc: f.inserted_at, desc: f.id)
    |> Repo.all()
    |> Enum.drop(keep)
    |> Enum.each(&Repo.delete/1)

    :ok
  end

  # ---- summary (one per user) ----
  def get_summary(user_id) do
    Repo.one(from s in Summary, where: s.user_id == ^user_id) ||
      %Summary{content: "", user_id: user_id}
  end

  def put_summary(user_id, content) do
    %Summary{}
    |> Summary.changeset(%{content: content, user_id: user_id})
    |> Repo.insert(on_conflict: {:replace, [:content, :updated_at]}, conflict_target: [:user_id])
  end

  # ---- reset ----
  @doc """
  Forget a user's conversation: wipe their turns, rolling summary, and auto-facts.
  User-curated facts (source == "user") are preserved. Notifies subscribers so an
  open LiveView reflects the clean slate.
  """
  def reset(user_id) do
    Repo.delete_all(from t in Turn, where: t.user_id == ^user_id)
    Repo.delete_all(from f in ProfileFact, where: f.user_id == ^user_id and f.source == "auto")
    put_summary(user_id, "")
    broadcast_updated()
    :ok
  end

  @doc "Wipe a user's conversation turns only; keeps facts + summary."
  def clear_turns(user_id) do
    Repo.delete_all(from t in Turn, where: t.user_id == ^user_id)
    broadcast_updated()
    :ok
  end

  @doc "Forget EVERYTHING about a user: all profile facts (auto AND user) + their summary."
  def forget(user_id) do
    Repo.delete_all(from f in ProfileFact, where: f.user_id == ^user_id)
    Repo.delete_all(from s in Summary, where: s.user_id == ^user_id)
    broadcast_updated()
    :ok
  end

  # ---- full-text recall (FTS5 over all past turns) ----
  @doc """
  Full-text search over ALL of a user's past turns (FTS5). Returns up to `limit` snippet maps
  `%{when:, you:, henry:}`, best-match first. The query is sanitized into quoted OR-terms so
  user speech can't break FTS syntax.
  """
  def search_turns(user_id, query, limit \\ 6) do
    case fts_query(query) do
      "" ->
        []

      match ->
        sql = """
        SELECT t.user_text, t.brain_text, t.inserted_at
        FROM turns_fts f JOIN turns t ON t.id = f.rowid
        WHERE turns_fts MATCH ?1 AND t.user_id = ?2
        ORDER BY bm25(turns_fts) LIMIT ?3
        """

        %{rows: rows} = Ecto.Adapters.SQL.query!(Repo, sql, [match, user_id, limit])

        Enum.map(rows, fn [you, henry, inserted_at] ->
          %{
            when: inserted_at |> to_string() |> String.slice(0, 10),
            you: snippet(you),
            henry: snippet(henry)
          }
        end)
    end
  end

  # each term quoted -> literal token match, OR'd; strips FTS operators entirely
  defp fts_query(query) when is_binary(query) do
    query
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.take(8)
    |> Enum.map(&~s|"#{&1}"|)
    |> Enum.join(" OR ")
  end

  defp fts_query(_), do: ""

  defp snippet(nil), do: nil
  defp snippet(text), do: String.slice(text, 0, 200)

  # ---- daily digests (nightly consolidation substrate) ----
  @doc "Digests, newest first."
  def digests_for(user_id, limit) do
    from(d in Digest,
      where: d.user_id == ^user_id,
      order_by: [desc: d.date],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Insert a day's digest. The unique (user_id, date) index makes this the once-per-day claim."
  def put_digest(user_id, date, content) do
    %Digest{}
    |> Digest.changeset(%{user_id: user_id, date: date, content: content})
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc "All turns whose inserted_at falls on the given UTC date (for the daily digest)."
  def turns_on(user_id, %Date{} = date) do
    {:ok, from_dt} = DateTime.new(date, ~T[00:00:00], "Etc/UTC")
    to_dt = DateTime.add(from_dt, 86_400, :second)

    from(t in Turn,
      where: t.user_id == ^user_id and t.inserted_at >= ^from_dt and t.inserted_at < ^to_dt,
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Transactionally replace all of a user's auto facts with `contents` (one fact per entry).
  Only source == "auto" rows are touched — source == "user" (curated) facts are NEVER
  deleted or modified here.
  """
  def replace_auto_facts(user_id, contents) do
    Repo.transaction(fn ->
      from(f in ProfileFact, where: f.user_id == ^user_id and f.source == "auto")
      |> Repo.delete_all()

      for c <- contents do
        Repo.insert!(%ProfileFact{user_id: user_id, content: c, source: "auto"})
      end
    end)

    broadcast_updated()
    :ok
  end
end
