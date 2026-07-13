defmodule App.Test.SpeakerFixtures do
  @moduledoc "Reads a fixture WAV's PCM payload, skipping non-audio RIFF chunks (ffmpeg LIST/INFO)."
  @dir "test/support/fixtures/speaker"

  @doc "PCM16 payload bytes of a fixture WAV (e.g. \"a1.wav\")."
  def read_pcm(name) do
    Path.join(@dir, name) |> File.read!() |> pcm_data()
  end

  defp pcm_data(<<"RIFF", _size::little-32, "WAVE", rest::binary>>), do: find_data(rest)

  defp find_data(<<"data", size::little-32, payload::binary-size(size), _rest::binary>>),
    do: payload

  defp find_data(<<_id::binary-size(4), size::little-32, rest::binary>>) do
    pad = rem(size, 2)
    <<_chunk::binary-size(size + pad), rest::binary>> = rest
    find_data(rest)
  end
end
