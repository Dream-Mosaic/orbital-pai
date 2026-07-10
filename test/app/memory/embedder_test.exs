defmodule App.Memory.EmbedderTest do
  use App.DataCase, async: false
  import ExUnit.CaptureLog
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

  test "an embeddings failure leaves rows unembedded, does not crash, and logs it", %{uid: uid} do
    Memory.persist_turn(%{user_id: uid, user_text: "x", brain_text: "y"})
    Application.put_env(:app, :fake_embeddings_error, true)
    {result, log} = with_log(fn -> Embedder.run_user(uid) end)
    assert result == :ok
    assert [_] = Memory.unembedded_turns(uid, 10)
    assert log =~ "[embedder] turn batch for user #{uid} not indexed"
  end

  test "a short/mismatched embedding batch leaves rows unembedded (no over-stamp)", %{uid: uid} do
    Memory.persist_turn(%{user_id: uid, user_text: "x", brain_text: "y"})
    Application.put_env(:app, :fake_embeddings_drop_last, true)
    on_exit(fn -> Application.delete_env(:app, :fake_embeddings_drop_last) end)
    {result, log} = with_log(fn -> Embedder.run_user(uid) end)
    assert result == :ok
    assert [_] = Memory.unembedded_turns(uid, 10)
    assert log =~ "not indexed"
  end

  test "logs a positive per-batch signal on a successful run", %{uid: uid} do
    Memory.persist_turn(%{user_id: uid, user_text: "hello", brain_text: "hi"})
    {:ok, _d} = Memory.put_digest(uid, ~D[2026-07-03], "a day")

    log = with_info_level(fn -> assert :ok = Embedder.run_user(uid) end)
    assert log =~ "[embedder] indexed 1 turn(s) for user #{uid}"
    assert log =~ "[embedder] indexed 1 digest(s) for user #{uid}"
  end

  test "logs 'collection ready' on init" do
    log = with_info_level(fn -> start_supervised!(App.Memory.Embedder) end)
    assert log =~ "[embedder] collection ready"
  end

  # The suite runs at :warning; drop to :info for the duration so capture_log sees the positive
  # signals, then restore. (async: false → sync tests run in isolation, so this is safe.)
  defp with_info_level(fun) do
    prev = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: prev)
    end
  end
end
