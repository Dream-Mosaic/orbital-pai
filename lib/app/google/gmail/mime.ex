defmodule App.Google.Gmail.Mime do
  @moduledoc """
  Pure RFC 2822 message assembly for `messages.send`. `build/1` renders headers + body to a
  string; `encode/1` base64url-encodes it for the API's `raw` field. CR/LF is stripped from the
  `to`/`subject` fields so a stray newline can't inject extra headers.
  """

  @doc """
  Render `attrs` to an RFC 2822 string. `attrs`: `%{from, to, subject, body}` plus optional
  `in_reply_to` + `references` for a threaded reply.
  """
  def build(attrs) do
    headers =
      [
        {"From", sanitize(attrs[:from])},
        {"To", sanitize(attrs[:to])},
        {"Subject", sanitize(attrs[:subject] || "")},
        {"Content-Type", "text/plain; charset=UTF-8"}
      ] ++ reply_headers(attrs)

    header_block = headers |> Enum.map(fn {k, v} -> "#{k}: #{v}" end) |> Enum.join("\r\n")
    header_block <> "\r\n\r\n" <> (attrs[:body] || "")
  end

  @doc "base64url (no padding) of `build/1`, ready for the `raw` field."
  def encode(attrs), do: attrs |> build() |> Base.url_encode64(padding: false)

  defp reply_headers(%{in_reply_to: mid} = attrs) when is_binary(mid) do
    [{"In-Reply-To", mid}, {"References", attrs[:references] || mid}]
  end

  defp reply_headers(_), do: []

  defp sanitize(v) when is_binary(v), do: String.replace(v, ~r/[\r\n]/, "")
  defp sanitize(v), do: v
end
