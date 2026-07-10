defmodule App.Adapters.VectorStore do
  @moduledoc """
  A vector store for semantic memory. `Qdrant` is the real impl; a fake is used in tests. Resolved
  via `Application.get_env(:app, :vector_store)`. The `user_id` filter on `search`/`delete_by_user`
  is applied INSIDE the impl — callers cannot omit it.
  """
  @callback ensure_collection() :: :ok | {:error, term()}
  @callback upsert(points :: [map()]) :: :ok | {:error, term()}
  @callback search(vector :: [float()], user_id :: integer(), limit :: integer()) ::
              {:ok, [%{source: String.t(), id: integer()}]} | {:error, term()}
  @callback delete_by_user(user_id :: integer()) :: :ok | {:error, term()}

  @doc "The configured vector-store adapter."
  def impl, do: Application.fetch_env!(:app, :vector_store)
end
