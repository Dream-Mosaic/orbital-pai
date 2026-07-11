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
    purge_vectors(user_id)
    App.Sources.Items.delete_for_user(user_id)
    broadcast_updated()
    :ok
  end

  @doc "Wipe a user's conversation turns only; keeps facts + summary."
  def clear_turns(user_id) do
    Repo.delete_all(from t in Turn, where: t.user_id == ^user_id)
    purge_conversation_vectors(user_id)
    broadcast_updated()
    :ok
  end

  @doc """
  Forget EVERYTHING about a user: all profile facts (auto AND user), their summary, and their
  conversation turns — a full amnesia (the UI "Wipe memory" button). The transcript goes too, so
  the raw turns can't keep feeding recent-context after the wipe.
  """
  def forget(user_id) do
    Repo.delete_all(from f in ProfileFact, where: f.user_id == ^user_id)
    Repo.delete_all(from s in Summary, where: s.user_id == ^user_id)
    Repo.delete_all(from t in Turn, where: t.user_id == ^user_id)
    purge_vectors(user_id)
    App.Sources.Items.delete_for_user(user_id)
    broadcast_updated()
    :ok
  end

  # Best-effort vector-store purge: a failure is logged, never raised, so "forget me" in SQLite
  # is never blocked by a Qdrant hiccup.
  defp purge_vectors(user_id) do
    case App.Adapters.VectorStore.impl().delete_by_user(user_id) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("[memory] vector purge failed for #{user_id}: #{inspect(reason)}")
        :ok
    end
  end

  # clear_turns wipes CONVERSATION turns only — purge just the conversation vectors, NOT the
  # email/calendar index (which delete_by_user would also drop, orphaning source_items rows).
  defp purge_conversation_vectors(user_id) do
    case App.Adapters.VectorStore.impl().delete_by_user_sources(user_id, ["turn", "digest"]) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "[memory] conversation vector purge failed for #{user_id}: #{inspect(reason)}"
        )

        :ok
    end
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

  @doc "The text embedded for one turn: user + brain, one vector."
  def embed_text_for(%Turn{user_text: u, brain_text: b}), do: "#{u}\n#{b}"

  @doc """
  Hybrid recall: FTS5 (keyword) + Qdrant (semantic), fused with RRF, rendered from SQLite. Returns
  up to `limit` match maps, best-first. Degrades to FTS5-only if the vector leg is unavailable. The
  returned shape is the `recall_memory` contract.
  """
  def search(user_id, query, limit \\ 6) do
    leg_a = fts_turn_ids(user_id, query, 20)
    {leg_b, payloads} = vector_ids(user_id, query, 20)

    [leg_a, leg_b]
    |> rrf_fuse()
    |> Enum.take(limit)
    |> render_hits(user_id, payloads)
  end

  # FTS5 leg for fusion: ranked TURN ids (bm25 best-first). Mirrors search_turns/3's query.
  defp fts_turn_ids(user_id, query, limit) do
    case fts_query(query) do
      "" ->
        []

      match ->
        sql = """
        SELECT t.id
        FROM turns_fts f JOIN turns t ON t.id = f.rowid
        WHERE turns_fts MATCH ?1 AND t.user_id = ?2
        ORDER BY bm25(turns_fts) LIMIT ?3
        """

        %{rows: rows} = Ecto.Adapters.SQL.query!(Repo, sql, [match, user_id, limit])
        Enum.map(rows, fn [id] -> {"turn", id} end)
    end
  end

  # Semantic leg: embed the query, search the vector store. Returns the ranked {source, id} list AND
  # a %{{source, id} => payload} map (external sources render from payload — no SQLite row). Any
  # failure → {[], %{}} (degrade to FTS5).
  defp vector_ids(user_id, query, limit) do
    with {:ok, [vec]} <- App.Adapters.Embeddings.impl().embed([query], :query),
         {:ok, hits} <- App.Adapters.VectorStore.impl().search(vec, user_id, limit) do
      ranked = Enum.map(hits, fn %{source: s, id: id} -> {s, id} end)
      payloads = Map.new(hits, fn %{source: s, id: id, payload: p} -> {{s, id}, p} end)
      {ranked, payloads}
    else
      {:error, reason} ->
        require Logger
        Logger.warning("[recall] vector leg unavailable (#{inspect(reason)}); FTS5-only")
        {[], %{}}

      _ ->
        {[], %{}}
    end
  end

  # Load fused rows, preserving fused order. Conversations (turn/digest) load from SQLite by id
  # (ghost-drop preserved); external sources (email/calendar) render from the Qdrant payload carried
  # by the vector leg (no Google API call on the recall path). user_id re-checked defensively.
  defp render_hits(fused, user_id, payloads) do
    turn_ids = for {"turn", id} <- fused, do: id
    digest_ids = for {"digest", id} <- fused, do: id

    turns =
      from(t in Turn, where: t.id in ^turn_ids and t.user_id == ^user_id)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    digests =
      from(d in Digest, where: d.id in ^digest_ids and d.user_id == ^user_id)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(fused, fn
      {"turn", id} ->
        case turns[id] do
          nil ->
            []

          t ->
            [
              %{
                when: day(t.inserted_at),
                you: snippet(t.user_text),
                henry: snippet(t.brain_text),
                source: "turn"
              }
            ]
        end

      {"digest", id} ->
        case digests[id] do
          nil -> []
          d -> [%{when: to_string(d.date), summary: snippet(d.content), source: "digest"}]
        end

      {"email", _id} = key ->
        render_external(:email, payloads[key])

      {"calendar", _id} = key ->
        render_external(:calendar, payloads[key])

      _ ->
        []
    end)
  end

  defp render_external(_kind, nil), do: []

  defp render_external(:email, p) do
    [
      %{
        when: when_of(p),
        subject: p["subject"],
        from: p["from"],
        snippet: p["snippet"],
        link: p["link"],
        source: "email"
      }
    ]
  end

  defp render_external(:calendar, p) do
    [
      %{
        when: when_of(p),
        title: p["title"],
        when_human: p["when_human"],
        location: p["location"],
        link: p["link"],
        source: "calendar"
      }
    ]
  end

  defp when_of(%{"at" => at}) when is_binary(at), do: String.slice(at, 0, 10)
  defp when_of(_), do: nil

  defp day(inserted_at), do: inserted_at |> to_string() |> String.slice(0, 10)

  # ---- Reciprocal Rank Fusion (RRF) ----
  @doc """
  Reciprocal Rank Fusion of several ranked `{source, id}` lists. Each list contributes
  `1 / (k + rank)` (rank 1-based) to a doc's score; docs are deduped by `{source, id}` and returned
  best-first. `k = 60` is the standard constant.
  """
  def rrf_fuse(ranked_lists, k \\ 60) do
    ranked_lists
    |> Enum.flat_map(fn list ->
      list |> Enum.with_index(1) |> Enum.map(fn {doc, rank} -> {doc, 1.0 / (k + rank)} end)
    end)
    |> Enum.reduce(%{}, fn {doc, score}, acc -> Map.update(acc, doc, score, &(&1 + score)) end)
    |> Enum.sort_by(fn {_doc, score} -> -score end)
    |> Enum.map(fn {doc, _score} -> doc end)
  end

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

  # ---- embedding substrate (rows awaiting a vector) ----
  @doc "Turns not yet embedded (embedded_at IS NULL), oldest first, capped."
  def unembedded_turns(user_id, limit) do
    from(t in Turn,
      where: t.user_id == ^user_id and is_nil(t.embedded_at),
      order_by: [asc: t.inserted_at, asc: t.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Digests not yet embedded (embedded_at IS NULL), oldest first, capped."
  def unembedded_digests(user_id, limit) do
    from(d in Digest,
      where: d.user_id == ^user_id and is_nil(d.embedded_at),
      order_by: [asc: d.date, asc: d.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Stamp embedded_at on the given turn/digest ids (after a confirmed vector upsert)."
  def mark_embedded(:turn, ids), do: stamp_embedded(Turn, ids)
  def mark_embedded(:digest, ids), do: stamp_embedded(Digest, ids)

  defp stamp_embedded(_schema, []), do: :ok

  defp stamp_embedded(schema, ids) do
    now = DateTime.utc_now()
    from(r in schema, where: r.id in ^ids) |> Repo.update_all(set: [embedded_at: now])
    :ok
  end
end
