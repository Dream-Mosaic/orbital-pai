defmodule App.MemorySearchTest do
  use App.DataCase, async: false
  import ExUnit.CaptureLog
  alias App.Memory
  alias App.Test.Fakes.VectorStore

  setup do
    VectorStore.reset()

    Application.put_env(:app, :allowed_users, [
      %{email: "s1@x.com", name: "S1"},
      %{email: "s2@x.com", name: "S2"}
    ])

    on_exit(fn ->
      Application.delete_env(:app, :allowed_users)
      Application.delete_env(:app, :fake_vector_error)
      Application.delete_env(:app, :fake_embeddings_error)
    end)

    {:ok, u1} = App.Users.upsert_allowed("s1@x.com")
    {:ok, u2} = App.Users.upsert_allowed("s2@x.com")
    %{u1: u1.id, u2: u2.id}
  end

  # Index a turn the way the Embedder would (embed doc text → upsert point).
  defp index_turn(uid, user_text, brain_text) do
    {:ok, t} = Memory.persist_turn(%{user_id: uid, user_text: user_text, brain_text: brain_text})
    {:ok, [v]} = App.Adapters.Embeddings.impl().embed([Memory.embed_text_for(t)], :document)

    :ok =
      VectorStore.upsert([
        %{
          id: "turn:#{t.id}",
          vector: v,
          payload: %{user_id: uid, source: "turn", source_id: t.id, text: t.user_text, at: "x"}
        }
      ])

    t
  end

  test "hybrid search returns turn matches in the today shape", %{u1: uid} do
    index_turn(uid, "the thai place on main", "you loved the drunken noodles")
    matches = Memory.search(uid, "thai restaurant", 6)
    assert Enum.any?(matches, &match?(%{you: _, henry: _, source: "turn"}, &1))
  end

  test "returns digest matches with a summary field", %{u1: uid} do
    {:ok, d} = Memory.put_digest(uid, ~D[2026-07-02], "talked about the garden and tomatoes")

    :ok =
      VectorStore.upsert([
        %{
          id: "digest:#{d.id}",
          vector: [0.0],
          payload: %{user_id: uid, source: "digest", source_id: d.id, text: d.content, at: "x"}
        }
      ])

    matches = Memory.search(uid, "anything", 6)

    assert Enum.any?(
             matches,
             &match?(%{summary: "talked about the garden and tomatoes", source: "digest"}, &1)
           )
  end

  test "user isolation: user 2 never sees user 1's memory", %{u1: u1, u2: u2} do
    index_turn(u1, "u1 secret sushi", "noted")
    assert Memory.search(u2, "sushi", 6) == []
  end

  test "degrades to FTS5-only when the vector store is down (and logs the fallback)", %{u1: uid} do
    Memory.persist_turn(%{user_id: uid, user_text: "keyword pizza night", brain_text: "yum"})
    Application.put_env(:app, :fake_vector_error, true)

    {matches, log} = with_log(fn -> Memory.search(uid, "pizza", 6) end)
    assert Enum.any?(matches, &(&1[:source] == "turn"))
    assert log =~ "[recall] vector leg unavailable"
  end

  test "degrades to FTS5-only when the query embed is down (and logs the fallback)", %{u1: uid} do
    Memory.persist_turn(%{user_id: uid, user_text: "keyword tacos", brain_text: "ole"})
    Application.put_env(:app, :fake_embeddings_error, true)

    {matches, log} = with_log(fn -> Memory.search(uid, "tacos", 6) end)
    assert is_list(matches)
    assert log =~ "[recall] vector leg unavailable"
  end

  test "ghost-drop: a vector hit whose SQLite row was deleted is not returned", %{u1: uid} do
    index_turn(uid, "ephemeral note", "ok")
    Memory.clear_turns(uid)
    refute Enum.any?(Memory.search(uid, "ephemeral", 6), &(&1[:source] == "turn"))
  end

  test "an unknown vector source is dropped, not raised (render_hits fallback)", %{u1: uid} do
    Memory.persist_turn(%{user_id: uid, user_text: "known keyword banana", brain_text: "ok"})

    :ok =
      VectorStore.upsert([
        %{
          id: "gmail:1",
          vector: [0.0],
          payload: %{user_id: uid, source: "gmail", source_id: 999, text: "x", at: "x"}
        }
      ])

    matches = Memory.search(uid, "banana", 6)
    assert is_list(matches)
    refute Enum.any?(matches, &(&1[:source] == "gmail"))
  end
end
