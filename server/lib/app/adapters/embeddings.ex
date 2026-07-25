defmodule App.Adapters.Embeddings do
  @moduledoc """
  Text → embedding vectors. `Voyage` hits the Voyage API; a fake returns deterministic vectors in
  tests. Resolved via `Application.get_env(:app, :embeddings)`.
  """
  @callback embed(texts :: [String.t()], input_type :: :query | :document) ::
              {:ok, [[float()]]} | {:error, term()}

  @doc "The configured embeddings adapter."
  def impl, do: Application.fetch_env!(:app, :embeddings)
end
