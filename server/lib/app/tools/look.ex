defmodule App.Tools.Look do
  @moduledoc """
  "Henry, look at this" (spec 2026-10-23-game-night-design, section 1): `look(question)` takes
  one photo with the BOUND device's camera (`App.Camera`) and asks the vision model about it
  (`describe_image/3` on the text model), returning `%{seen: answer, capture_id: id}` for the
  brain to say in its own voice. The photo card (`App.Cards`, type `photo`) carries the
  capture id; the app shows the snapshot it kept in memory.

  Always on, not a toolkit, so "look at this" never spends a `use_toolkit` hop. Failures are
  sentences the brain can say as they are. Privacy: the image is sent to Gemini and nowhere
  else — never stored, never logged; the one `[look]` line per capture carries sizes and
  timings (and the question only through `App.LogText.said/1`).
  """
  @behaviour App.Tools.Tool

  require Logger

  @no_device "I can't see from this device."
  @no_answer "The camera didn't answer."
  @blurry "I couldn't make anything out."

  @default_question "What is this?"
  @max_question 500

  @impl true
  def declarations do
    [
      %{
        name: "look",
        description:
          "Take one photo with the camera of the device the user is talking to and look at " <>
            "it: what they're holding up or showing you. Returns `seen`, what's in the photo " <>
            "as it bears on their question. The photo shows on their screen.",
        parameters: %{
          type: "object",
          properties: %{
            question: %{
              type: "string",
              description:
                "What to find out, in the user's words: \"what is this\", \"how many " <>
                  "fingers am I holding up\", \"read this label\"."
            }
          },
          required: ["question"]
        }
      }
    ]
  end

  @impl true
  def prompt do
    "You can see through the camera of the device the user is talking to: use look whenever " <>
      "they ask you to look at, see, read, identify, count or describe something they're " <>
      "showing you (\"what am I holding?\", \"read this\", \"how many fingers?\"), with their " <>
      "question in their words. Never guess what's in front of the camera — look. Say what " <>
      "`seen` tells you briefly, in your own voice; if it fails, say so plainly."
  end

  @impl true
  def bridge("look"), do: ["Let me look.", "Let me take a look.", "Hold it still, let me look."]
  def bridge(_name), do: []

  # Up to 12 s for the photo (the app's 2.4 s countdown included) + the vision call's own
  # 11 s cap: comfortably under this. The TTS context rotates meanwhile, so a slow look is fine.
  @impl true
  def timeout("look"), do: 25_000

  @impl true
  def execute("look", args, ctx) do
    question = question(args)
    config = Map.get(ctx, :config) || %App.Config{}

    case App.Camera.request(Map.get(ctx, :session_id)) do
      {:ok, capture} ->
        started = System.monotonic_time(:millisecond)
        seen = vision(capture.jpeg, question, config)
        vision_ms = System.monotonic_time(:millisecond) - started
        App.Camera.done(capture)
        log_capture(capture, vision_ms, seen, question)

        case seen do
          {:ok, text} -> {:ok, %{seen: text, capture_id: capture.id}}
          {:error, _reason} -> {:error, @blurry}
        end

      {:error, reason} ->
        Logger.info("[look] no photo: #{describe_error(reason)} #{App.LogText.said(question)}")
        {:error, error_for(reason)}
    end
  end

  @doc false
  # The question as the vision model will get it: trimmed and capped; a missing or blank one
  # asks what the thing is. Also the photo card's caption (App.Cards), so both agree.
  def question(args) do
    case is_map(args) && args["question"] do
      q when is_binary(q) ->
        case String.trim(q) do
          "" -> @default_question
          q -> String.slice(q, 0, @max_question)
        end

      _ ->
        @default_question
    end
  end

  defp vision(jpeg, question, config) do
    case text_model().describe_image(jpeg, question, config: config) do
      {:ok, text} when is_binary(text) and text != "" -> {:ok, text}
      {:ok, _blank} -> {:error, :empty}
      {:error, reason} -> {:error, reason}
    end
  end

  # What the brain can say for each way a capture fails (spec section 1).
  defp error_for(:no_device), do: @no_device
  defp error_for({:device, reason}) when reason in ["no_camera", "denied"], do: @no_device
  defp error_for(:timeout), do: @no_answer
  defp error_for({:device, _failed}), do: @no_answer
  defp error_for(reason) when reason in [:bad_frame, :too_large], do: @blurry
  defp error_for(_other), do: @no_answer

  # Sizes and timings only: never the image, never what the model saw.
  defp log_capture(capture, vision_ms, seen, question) do
    outcome =
      case seen do
        {:ok, _} -> "vision #{secs(vision_ms)}"
        {:error, reason} -> "vision FAILED after #{secs(vision_ms)}: #{describe_error(reason)}"
      end

    Logger.info(
      "[look] captured #{kb(byte_size(capture.jpeg))} (#{capture.facing}) in " <>
        "#{secs(capture.capture_ms)}; #{outcome} #{App.LogText.said(question)}"
    )
  end

  defp describe_error({:device, reason}) when is_binary(reason),
    do: "device said #{inspect(String.slice(reason, 0, 40))}"

  defp describe_error({:http, status}), do: "HTTP #{status}"
  defp describe_error(reason) when is_atom(reason), do: to_string(reason)
  defp describe_error(%{__exception__: true} = e), do: inspect(e.__struct__)
  defp describe_error(_other), do: "error"

  defp kb(bytes), do: "#{max(1, round(bytes / 1024))} KB"
  defp secs(ms), do: "#{Float.round(ms / 1000, 1)} s"

  defp text_model, do: Application.fetch_env!(:app, :text_model)
end
