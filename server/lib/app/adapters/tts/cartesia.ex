defmodule App.Adapters.Tts.Cartesia do
  @moduledoc """
  Cartesia TTS via REST `/tts/bytes`. Returns the whole clip as raw PCM16 at the
  session sample rate; the Conversation chunks + times it. Verify the API version
  header against current Cartesia docs before relying on it.
  """
  @behaviour App.Adapters.Tts

  @impl true
  def synthesize(text, opts) do
    case Req.post("https://api.cartesia.ai/tts/bytes",
           finch: App.Finch,
           headers: [
             {"X-API-Key", System.fetch_env!("CARTESIA_API_KEY")},
             {"Cartesia-Version", Keyword.get(opts, :version, "2024-11-13")}
           ],
           json: build_body(text, opts),
           decode_body: false,
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: pcm}} when is_binary(pcm) -> {:ok, pcm}
      {:ok, %{status: s, body: b}} -> {:error, {:http, s, b}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def build_body(text, opts) do
    %{
      model_id: Keyword.get(opts, :model, "sonic-2"),
      transcript: text,
      voice: %{mode: "id", id: Keyword.fetch!(opts, :voice_id)},
      generation_config:
        generation_config(
          Keyword.fetch!(opts, :tts_speed),
          Keyword.fetch!(opts, :tts_volume),
          Keyword.get(opts, :tts_emotion)
        ),
      output_format: %{
        container: "raw",
        encoding: "pcm_s16le",
        sample_rate: Keyword.get(opts, :sample_rate, 16_000)
      }
    }
  end

  @doc "Cartesia generation_config map; emotion is omitted when nil/blank (→ neutral)."
  def generation_config(speed, volume, emotion) do
    base = %{speed: speed, volume: volume}
    if emotion in [nil, ""], do: base, else: Map.put(base, :emotion, emotion)
  end
end
