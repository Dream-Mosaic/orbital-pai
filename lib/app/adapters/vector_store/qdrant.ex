defmodule App.Adapters.VectorStore.Qdrant do
  @moduledoc """
  Qdrant REST client (single collection, payload-partitioned by user_id). Runs on `App.Finch`.
  Every search/delete applies the `user_id` filter here so callers cannot leak across users.
  Point IDs are deterministic UUIDv5 (`point_id/2`) so re-upserts converge instead of duplicating.
  Collection name + vector dims come from `App.Config`.
  """
  @behaviour App.Adapters.VectorStore
  import Bitwise
  require Logger

  # Fixed application namespace for UUIDv5 (any constant 16 bytes; DO NOT change once data exists).
  @namespace <<0x1B, 0x67, 0x1A, 0x64, 0x40, 0xD5, 0x49, 0x1E, 0x99, 0xB0, 0xDA, 0x01, 0xFF, 0x1F,
               0x33, 0x41>>

  defp collection, do: App.Config.default().qdrant_collection
  defp dims, do: App.Config.default().embed_dims

  @impl true
  def ensure_collection do
    name = collection()

    case req(:get, "/collections/#{name}/exists") do
      {:ok, %{"result" => %{"exists" => true}}} ->
        :ok

      {:ok, _} ->
        with :ok <- create_collection(name), do: create_indexes(name)

      {:error, reason} ->
        Logger.warning("[qdrant] ensure_collection failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp create_collection(name) do
    case req(:put, "/collections/#{name}", %{vectors: %{size: dims(), distance: "Cosine"}}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_indexes(name) do
    with {:ok, _} <-
           req(:put, "/collections/#{name}/index", %{
             field_name: "user_id",
             field_schema: "integer"
           }),
         {:ok, _} <-
           req(:put, "/collections/#{name}/index", %{
             field_name: "source",
             field_schema: "keyword"
           }) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def upsert([]), do: :ok

  def upsert(points) do
    case req(:put, "/collections/#{collection()}/points?wait=true", %{points: points}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def search(vector, user_id, limit) do
    body = %{
      query: vector,
      filter: %{must: [%{key: "user_id", match: %{value: user_id}}]},
      limit: limit,
      with_payload: true
    }

    case req(:post, "/collections/#{collection()}/points/query", body) do
      {:ok, %{"result" => %{"points" => points}}} -> {:ok, Enum.map(points, &to_hit/1)}
      {:ok, _} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_hit(%{"payload" => %{"source" => s, "source_id" => id}}), do: %{source: s, id: id}

  @impl true
  def delete_by_user(user_id) do
    body = %{filter: %{must: [%{key: "user_id", match: %{value: user_id}}]}}

    case req(:post, "/collections/#{collection()}/points/delete?wait=true", body) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ---- deterministic UUIDv5 (SHA1), no external dependency ----
  @doc "Deterministic UUIDv5 point id for a `(source, id)` pair."
  def point_id(source, id) do
    <<a::binary-size(4), b::binary-size(2), c0, c1, d0, d1, e::binary-size(6), _::binary>> =
      :crypto.hash(:sha, @namespace <> "#{source}:#{id}")

    c = <<(c0 &&& 0x0F) ||| 0x50, c1>>
    d = <<(d0 &&& 0x3F) ||| 0x80, d1>>

    Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))
  end

  # ---- HTTP ----
  defp req(method, path, body \\ nil) do
    opts =
      [method: method, url: base_url() <> path, finch: App.Finch, receive_timeout: 1_500] ++
        auth_header() ++
        body_opt(body) ++
        App.Http.Retry.opts() ++
        Application.get_env(:app, :qdrant_req_opts, [])

    case Req.request(opts) do
      {:ok, %{status: s, body: b}} when s in 200..299 -> {:ok, b}
      {:ok, %{status: s}} -> {:error, {:http, s}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp body_opt(nil), do: []
  defp body_opt(body), do: [json: body]

  defp base_url,
    do:
      Application.get_env(:app, :qdrant_url) || System.get_env("QDRANT_URL") ||
        "http://localhost:6333"

  defp auth_header do
    case Application.get_env(:app, :qdrant_api_key) || System.get_env("QDRANT_API_KEY") do
      nil -> []
      "" -> []
      key -> [headers: [{"api-key", key}]]
    end
  end
end
