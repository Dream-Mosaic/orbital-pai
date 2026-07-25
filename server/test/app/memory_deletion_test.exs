defmodule App.MemoryDeletionTest do
  use App.DataCase, async: false
  alias App.Memory
  alias App.Test.Fakes.VectorStore

  setup do
    VectorStore.reset()
    Application.put_env(:app, :allowed_users, [%{email: "d@x.com", name: "D"}])

    on_exit(fn ->
      Application.delete_env(:app, :allowed_users)
      Application.delete_env(:app, :fake_vector_error)
    end)

    {:ok, u} = App.Users.upsert_allowed("d@x.com")
    %{uid: u.id}
  end

  defp seed_vector(uid) do
    VectorStore.upsert([
      %{
        id: "turn:1",
        vector: [0.0],
        payload: %{user_id: uid, source: "turn", source_id: 1, text: "t", at: "x"}
      }
    ])
  end

  test "clear_turns purges the user's vectors", %{uid: uid} do
    seed_vector(uid)
    :ok = Memory.clear_turns(uid)
    assert {:ok, []} = VectorStore.search([0.0], uid, 20)
  end

  test "reset purges the user's vectors", %{uid: uid} do
    seed_vector(uid)
    :ok = Memory.reset(uid)
    assert {:ok, []} = VectorStore.search([0.0], uid, 20)
  end

  test "forget purges the user's vectors", %{uid: uid} do
    seed_vector(uid)
    :ok = Memory.forget(uid)
    assert {:ok, []} = VectorStore.search([0.0], uid, 20)
  end

  test "a vector-store failure does not raise", %{uid: uid} do
    seed_vector(uid)
    Application.put_env(:app, :fake_vector_error, true)
    assert :ok = Memory.clear_turns(uid)
  end
end
