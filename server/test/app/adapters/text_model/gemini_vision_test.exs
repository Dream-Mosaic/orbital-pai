defmodule App.Adapters.TextModel.GeminiVisionTest do
  # async: false — the Req test plug rides global app env (:gemini_req_opts).
  use ExUnit.Case, async: false

  alias App.Adapters.TextModel.Gemini
  alias App.Config

  # "Henry, look at this" (spec 2026-10-23-game-night-design, section 1): ONE generateContent
  # call with the photo as an inlineData part plus the user's question.

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, "pixels">>

  setup do
    Application.put_env(:app, :gemini_req_opts, plug: {Req.Test, GeminiVisionStub})
    on_exit(fn -> Application.delete_env(:app, :gemini_req_opts) end)
    :ok
  end

  defp answer(text),
    do: %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text}]}}]}

  defp stub_capturing(response) do
    test = self()

    Req.Test.stub(GeminiVisionStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test,
        {:request, conn.request_path, Plug.Conn.get_req_header(conn, "x-goog-api-key"),
         Jason.decode!(body)}
      )

      Req.Test.json(conn, response)
    end)
  end

  test "sends the image as inlineData (image/jpeg) plus the question, and returns the text" do
    stub_capturing(answer("  A red coffee mug with a chipped handle.  "))

    assert {:ok, "A red coffee mug with a chipped handle."} =
             Gemini.describe_image(@jpeg, "what am I holding?",
               config: %Config{},
               api_key: "test-key"
             )

    assert_received {:request, path, ["test-key"], body}
    assert path == "/v1beta/models/gemini-3.8-flash:generateContent"

    assert [%{"role" => "user", "parts" => parts}] = body["contents"]
    assert %{"inlineData" => %{"mimeType" => "image/jpeg", "data" => data}} = Enum.at(parts, 0)
    assert Base.decode64!(data) == @jpeg
    assert %{"text" => text} = Enum.at(parts, 1)
    assert text =~ "what am I holding?"

    assert body["generationConfig"]["thinkingConfig"]["thinkingLevel"] == "low"
    assert is_integer(body["generationConfig"]["maxOutputTokens"])
    assert [%{"text" => system}] = body["systemInstruction"]["parts"]
    assert system =~ ~r/never (guess|invent)/i
  end

  test "uses :model_vision when set, else the brain model" do
    stub_capturing(answer("ok"))

    Gemini.describe_image(@jpeg, "q",
      config: %Config{model_vision: "gemini-vision-x"},
      api_key: "k"
    )

    assert_received {:request, "/v1beta/models/gemini-vision-x:generateContent", _, _}

    Gemini.describe_image(@jpeg, "q", config: %Config{model_brain: "brainy"}, api_key: "k")
    assert_received {:request, "/v1beta/models/brainy:generateContent", _, _}
  end

  test "an HTTP error is an error (status only, never the body)" do
    Req.Test.stub(GeminiVisionStub, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => %{"message" => "bad"}})
    end)

    assert {:error, {:http, 400}} =
             Gemini.describe_image(@jpeg, "q", config: %Config{}, api_key: "k")
  end

  test "an empty answer is an error, not a blank result" do
    stub_capturing(%{"candidates" => [%{"content" => %{"parts" => []}}]})
    assert {:error, :empty} = Gemini.describe_image(@jpeg, "q", config: %Config{}, api_key: "k")
  end

  test "no API key is an error, not a crash" do
    assert {:error, :no_api_key} =
             Gemini.describe_image(@jpeg, "q", config: %Config{}, api_key: nil)
  end
end
