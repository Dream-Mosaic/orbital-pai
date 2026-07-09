defmodule App.Google.Gmail.BodyTest do
  use ExUnit.Case, async: true

  alias App.Google.Gmail.Body

  defp b64(s), do: Base.url_encode64(s, padding: false)

  test "extracts a single text/plain part" do
    payload = %{"mimeType" => "text/plain", "body" => %{"data" => b64("hello world")}}
    assert Body.extract(payload) == "hello world"
  end

  test "prefers text/plain over text/html in a multipart/alternative" do
    payload = %{
      "mimeType" => "multipart/alternative",
      "parts" => [
        %{"mimeType" => "text/plain", "body" => %{"data" => b64("plain version")}},
        %{"mimeType" => "text/html", "body" => %{"data" => b64("<p>html version</p>")}}
      ]
    }

    assert Body.extract(payload) == "plain version"
  end

  test "finds text/plain nested inside multipart/mixed > multipart/alternative" do
    payload = %{
      "mimeType" => "multipart/mixed",
      "parts" => [
        %{
          "mimeType" => "multipart/alternative",
          "parts" => [
            %{"mimeType" => "text/plain", "body" => %{"data" => b64("deep plain")}}
          ]
        }
      ]
    }

    assert Body.extract(payload) == "deep plain"
  end

  test "falls back to stripped text/html when no plaintext part exists" do
    payload = %{
      "mimeType" => "text/html",
      "body" => %{"data" => b64("<div>Hi&nbsp;<b>there</b></div><p>line two</p>")}
    }

    result = Body.extract(payload)
    assert result =~ "Hi there"
    assert result =~ "line two"
    refute result =~ "<"
  end

  test "decodes base64url (URL-safe alphabet, no padding)" do
    # ">>>" base64-encodes to "Pj4+" in standard, "Pj4-" in URL-safe — must decode the latter.
    payload = %{"mimeType" => "text/plain", "body" => %{"data" => "Pj4-"}}
    assert Body.extract(payload) == ">>>"
  end

  test "returns empty string when there is no readable part" do
    assert Body.extract(%{"mimeType" => "multipart/mixed", "parts" => []}) == ""
    assert Body.extract(%{"mimeType" => "image/png", "body" => %{}}) == ""
  end
end
