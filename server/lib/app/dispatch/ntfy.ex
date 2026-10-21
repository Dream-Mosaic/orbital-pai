defmodule App.Dispatch.Ntfy do
  @moduledoc """
  Phone push via ntfy: `POST {url}/{topic}` with the message as the body. Config:
  `:app, :ntfy` -> `%{url:, topic:, token:}` (token optional, sent as a Bearer header). Req
  options are overridable via `:ntfy_req_opts` (test seam). One attempt, no retry: a missed push
  is not worth a retry loop, and the wall line is the backstop. Failures log the status or
  exception only, never the URL, topic or token.
  """
  require Logger

  @spec publish(map()) :: :ok | {:error, term()}
  def publish(%{} = msg) do
    case Application.get_env(:app, :ntfy) do
      %{url: url, topic: topic} = cfg when is_binary(url) and url != "" and is_binary(topic) ->
        send_it(cfg, msg)

      _ ->
        {:error, :not_configured}
    end
  end

  defp send_it(%{url: url, topic: topic} = cfg, msg) do
    opts =
      [
        method: :post,
        url: "#{String.trim_trailing(url, "/")}/#{topic}",
        body: msg[:message] || "",
        headers: headers(cfg, msg),
        retry: false,
        receive_timeout: 8_000
      ] ++ Application.get_env(:app, :ntfy_req_opts, [])

    case Req.request(opts) do
      {:ok, %{status: s}} when s in 200..299 ->
        :ok

      {:ok, %{status: s}} ->
        Logger.warning("ntfy publish failed: HTTP #{s}")
        {:error, {:http, s}}

      {:error, e} ->
        Logger.warning("ntfy publish failed: #{Exception.message(e)}")
        {:error, e}
    end
  end

  # A header value must not carry CR/LF or non-ASCII; drop a Click that does.
  defp printable_ascii?(v), do: String.match?(v, ~r/\A[\x20-\x7e]+\z/)

  defp headers(cfg, msg) do
    base =
      for {h, k} <- [
            {"Title", :title},
            {"Click", :click},
            {"Tags", :tags},
            {"Priority", :priority}
          ],
          v = msg[k],
          is_binary(v) and v != "",
          k != :click or printable_ascii?(v),
          do: {h, v}

    case cfg[:token] do
      t when is_binary(t) and t != "" -> base ++ [{"Authorization", "Bearer " <> t}]
      _ -> base
    end
  end
end
