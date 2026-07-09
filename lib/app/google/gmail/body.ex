defmodule App.Google.Gmail.Body do
  @moduledoc """
  Pure extraction of best-effort plaintext from a Gmail message `payload` (the MIME tree from
  `messages.get?format=full`). Prefers any `text/plain` leaf; falls back to the first `text/html`
  leaf stripped to rough plaintext (good enough for TTS — most real mail is multipart with a
  plaintext part anyway). Part bodies are base64url; an unreadable message yields `""`.
  """

  @doc "Best-effort plaintext for a Gmail message payload map."
  def extract(payload) when is_map(payload) do
    leaves = leaves(payload)
    plain = Enum.find(leaves, &String.starts_with?(&1.mime, "text/plain"))
    html = Enum.find(leaves, &String.starts_with?(&1.mime, "text/html"))

    cond do
      plain -> String.trim(plain.text)
      html -> html.text |> strip_html() |> String.trim()
      true -> ""
    end
  end

  def extract(_), do: ""

  # Flatten the MIME tree to decoded leaf parts that actually carry data.
  defp leaves(%{"mimeType" => mime, "body" => %{"data" => data}}) when is_binary(data),
    do: [%{mime: mime, text: decode(data)}]

  defp leaves(%{"parts" => parts}) when is_list(parts), do: Enum.flat_map(parts, &leaves/1)
  defp leaves(_), do: []

  defp decode(data) do
    case Base.url_decode64(data, padding: false) do
      {:ok, bytes} -> bytes
      :error -> ""
    end
  end

  # Crude HTML → text: drop tags, decode the handful of entities that matter for speech,
  # collapse runs of whitespace. Not a real parser — just enough to read aloud.
  defp strip_html(html) do
    html
    |> String.replace(~r{<\s*(br|/p|/div|/li|/tr)\s*/?>}i, "\n")
    |> String.replace(~r{<[^>]*>}, "")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
  end
end
