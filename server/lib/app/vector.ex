defmodule App.Vector do
  @moduledoc """
  Shared write primitive for the semantic store: embed a batch of texts (Voyage `:document`) and
  upsert them as points. Used by `App.Sources.Ingester`. Refuses to upsert a batch whose vector
  count doesn't match the item count (so a truncated embedding response can't misalign payloads).
  """
  alias App.Adapters.{Embeddings, VectorStore}

  @doc "Embed each item's `embed_text` and upsert `%{id: point_id, vector, payload}`. Empty → :ok."
  def embed_and_upsert([]), do: :ok

  def embed_and_upsert(items) when is_list(items) do
    texts = Enum.map(items, & &1.embed_text)

    with {:ok, vectors} <- Embeddings.impl().embed(texts, :document),
         true <- length(vectors) == length(items),
         points = zip_points(items, vectors),
         :ok <- VectorStore.impl().upsert(points) do
      :ok
    else
      false -> {:error, :embedding_count_mismatch}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp zip_points(items, vectors) do
    Enum.zip_with(items, vectors, fn item, vector ->
      %{id: item.point_id, vector: vector, payload: item.payload}
    end)
  end
end
