defmodule App.Adapters.Embeddings.Voyage do
  @moduledoc """
  Voyage AI embeddings (`voyage-4-lite`, 1024 dims — from `App.Config`). Batch endpoint; response
  vectors are reordered by `index` so the result matches input order. Runs on `App.Finch` with
  transient-safe retries. The query path uses a tight timeout so a slow Voyage can't stall a voice
  turn (the caller degrades to FTS5 on `{:error, _}`).
  """
  @behaviour App.Adapters.Embeddings

  @url "https://api.voyageai.com/v1/embeddings"

  @impl true
  def embed([], _input_type), do: {:ok, []}

  def embed(texts, input_type) when is_list(texts) do
    cfg = App.Config.default()

    body = %{
      input: texts,
      model: cfg.embed_model,
      input_type: to_string(input_type),
      output_dimension: cfg.embed_dims
    }

    opts =
      [
        json: body,
        auth: {:bearer, api_key()},
        finch: App.Finch,
        receive_timeout: timeout(input_type)
      ] ++ App.Http.Retry.opts() ++ Application.get_env(:app, :voyage_req_opts, [])

    case Req.post(@url, opts) do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, sort_vectors(data)}
      {:ok, %{status: s}} -> {:error, {:http, s}}
      {:error, reason} -> {:error, reason}
    end
  end

  # query embeds sit on the voice path → tight; document embeds are the background indexer → roomy.
  defp timeout(:query), do: 2_000
  defp timeout(:document), do: 15_000

  defp sort_vectors(data), do: data |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])

  defp api_key,
    do: Application.get_env(:app, :voyage_api_key) || System.get_env("VOYAGE_API_KEY") || ""
end
