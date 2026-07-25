defmodule App.MemoryEmbeddingTest do
  use App.DataCase, async: false
  alias App.Memory

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "e1@x.com", name: "E1"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, user} = App.Users.upsert_allowed("e1@x.com")
    %{user_id: user.id}
  end

  test "unembedded_turns returns only null-embedded turns, oldest first", %{user_id: uid} do
    {:ok, t1} = Memory.persist_turn(%{user_id: uid, user_text: "first", brain_text: "a"})
    {:ok, _t2} = Memory.persist_turn(%{user_id: uid, user_text: "second", brain_text: "b"})

    assert [a, b] = Memory.unembedded_turns(uid, 10)
    assert a.id == t1.id and a.user_text == "first"
    assert b.user_text == "second"

    Memory.mark_embedded(:turn, [t1.id])
    assert [only] = Memory.unembedded_turns(uid, 10)
    assert only.user_text == "second"
  end

  test "unembedded_digests excludes stamped digests", %{user_id: uid} do
    {:ok, d} = Memory.put_digest(uid, ~D[2026-07-01], "a quiet day")
    assert [got] = Memory.unembedded_digests(uid, 10)
    assert got.id == d.id

    Memory.mark_embedded(:digest, [d.id])
    assert [] = Memory.unembedded_digests(uid, 10)
  end
end
