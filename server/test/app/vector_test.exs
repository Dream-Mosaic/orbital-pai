defmodule App.VectorTest do
  use ExUnit.Case, async: false
  alias App.Test.Fakes.VectorStore

  setup do
    VectorStore.reset()

    on_exit(fn ->
      Application.delete_env(:app, :fake_embeddings_error)
      Application.delete_env(:app, :fake_embeddings_drop_last)
      Application.delete_env(:app, :fake_vector_error)
    end)

    :ok
  end

  defp item(id),
    do: %{
      point_id: "p#{id}",
      embed_text: "text #{id}",
      payload: %{
        user_id: 1,
        source: "email",
        # `source_id` is read by the CURRENT fake VectorStore.search/3 (M1 shape: %{source:, id:}).
        # `external_id`/`account_id` are the M2 source-item keys the real payload also carries.
        source_id: "7:m#{id}",
        external_id: "m#{id}",
        account_id: 7
      }
    }

  test "empty list is a no-op :ok" do
    assert App.Vector.embed_and_upsert([]) == :ok
  end

  test "embeds and upserts, one point per item" do
    assert App.Vector.embed_and_upsert([item(1), item(2)]) == :ok
    {:ok, hits} = VectorStore.search([0.0], 1, 10)
    assert length(hits) == 2
    assert Enum.all?(hits, &(&1.source == "email"))
  end

  test "a Voyage failure returns the error, upserts nothing" do
    Application.put_env(:app, :fake_embeddings_error, true)
    assert {:error, _} = App.Vector.embed_and_upsert([item(1)])
    assert {:ok, []} = VectorStore.search([0.0], 1, 10)
  end

  test "a short/mismatched embedding batch is an error, not an over-write" do
    Application.put_env(:app, :fake_embeddings_drop_last, true)
    assert {:error, :embedding_count_mismatch} = App.Vector.embed_and_upsert([item(1), item(2)])
    assert {:ok, []} = VectorStore.search([0.0], 1, 10)
  end
end
