defmodule App.Memory.EmbedderTest do
  use App.DataCase, async: false
  alias App.Memory
  alias App.Memory.Embedder
  alias App.Test.Fakes.VectorStore

  setup do
    VectorStore.reset()
    Application.put_env(:app, :allowed_users, [%{email: "emb@x.com", name: "Emb"}])

    on_exit(fn ->
      Application.delete_env(:app, :allowed_users)
      Application.delete_env(:app, :fake_embeddings_error)
    end)

    {:ok, u} = App.Users.upsert_allowed("emb@x.com")
    %{uid: u.id}
  end

  test "embeds unembedded turns + digests, upserts, stamps embedded_at", %{uid: uid} do
    {:ok, t} = Memory.persist_turn(%{user_id: uid, user_text: "hello", brain_text: "hi"})
    {:ok, _d} = Memory.put_digest(uid, ~D[2026-07-03], "a day")

    assert :ok = Embedder.run_user(uid)

    assert Memory.unembedded_turns(uid, 10) == []
    assert Memory.unembedded_digests(uid, 10) == []
    assert {:ok, hits} = VectorStore.search([0.0], uid, 20)
    assert Enum.any?(hits, &(&1 == %{source: "turn", id: t.id}))
    assert Enum.any?(hits, &(&1.source == "digest"))
  end

  test "is idempotent — a second run adds nothing", %{uid: uid} do
    Memory.persist_turn(%{user_id: uid, user_text: "x", brain_text: "y"})
    :ok = Embedder.run_user(uid)
    {:ok, before} = VectorStore.search([0.0], uid, 50)
    :ok = Embedder.run_user(uid)
    {:ok, after_} = VectorStore.search([0.0], uid, 50)
    assert length(before) == length(after_)
  end

  test "an embeddings failure leaves rows unembedded and does not crash", %{uid: uid} do
    Memory.persist_turn(%{user_id: uid, user_text: "x", brain_text: "y"})
    Application.put_env(:app, :fake_embeddings_error, true)
    assert :ok = Embedder.run_user(uid)
    assert [_] = Memory.unembedded_turns(uid, 10)
  end

  test "a short/mismatched embedding batch leaves rows unembedded (no over-stamp)", %{uid: uid} do
    Memory.persist_turn(%{user_id: uid, user_text: "x", brain_text: "y"})
    Application.put_env(:app, :fake_embeddings_drop_last, true)
    on_exit(fn -> Application.delete_env(:app, :fake_embeddings_drop_last) end)
    assert :ok = Embedder.run_user(uid)
    assert [_] = Memory.unembedded_turns(uid, 10)
  end
end
