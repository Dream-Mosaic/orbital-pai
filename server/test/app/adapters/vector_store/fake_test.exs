defmodule App.Test.Fakes.VectorStoreTest do
  use ExUnit.Case, async: false
  alias App.Test.Fakes.VectorStore

  setup do
    VectorStore.reset()
    on_exit(fn -> Application.delete_env(:app, :fake_vector_error) end)
    :ok
  end

  test "upsert then search returns only the caller's points" do
    :ok = VectorStore.upsert([point(1, "turn", 10), point(2, "turn", 20)])
    assert {:ok, [%{source: "turn", id: 10}]} = VectorStore.search([0.0], 1, 20)
  end

  test "re-upsert by id does not duplicate" do
    :ok = VectorStore.upsert([point(1, "turn", 10)])
    :ok = VectorStore.upsert([point(1, "turn", 10)])
    assert {:ok, [_only]} = VectorStore.search([0.0], 1, 20)
  end

  test "delete_by_user drops that user's points only" do
    :ok = VectorStore.upsert([point(1, "turn", 10), point(2, "turn", 20)])
    :ok = VectorStore.delete_by_user(1)
    assert {:ok, []} = VectorStore.search([0.0], 1, 20)
    assert {:ok, [%{id: 20}]} = VectorStore.search([0.0], 2, 20)
  end

  test "fake_vector_error forces failures" do
    Application.put_env(:app, :fake_vector_error, true)
    assert {:error, :fake_vector_down} = VectorStore.search([0.0], 1, 20)
    assert {:error, :fake_vector_down} = VectorStore.upsert([point(1, "turn", 1)])
  end

  defp point(user_id, source, source_id) do
    %{
      id: "#{source}:#{source_id}",
      vector: [0.0],
      payload: %{
        user_id: user_id,
        source: source,
        source_id: source_id,
        text: "t",
        at: "2026-07-09"
      }
    }
  end
end
