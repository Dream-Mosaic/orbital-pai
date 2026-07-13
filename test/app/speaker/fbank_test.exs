defmodule App.Speaker.FbankTest do
  use ExUnit.Case, async: true

  @dir "test/support/fixtures/speaker"

  test "matches the torchaudio kaldi fbank reference (mean abs diff < 0.05)" do
    {:ok, wav} = File.read(Path.join(@dir, "a1.wav"))
    # ffmpeg wrote a LIST/INFO chunk before "data" here, so a fixed 44-byte
    # strip grabs chunk metadata instead of samples — walk the RIFF chunks to
    # find the real "data" payload instead of assuming a fixed header size.
    pcm = pcm_data(wav)

    [t, mels] =
      Path.join(@dir, "fbank_ref_shape.txt")
      |> File.read!()
      |> String.split()
      |> Enum.map(&String.to_integer/1)

    ref =
      Path.join(@dir, "fbank_ref.bin")
      |> File.read!()
      |> Nx.from_binary(:f32)
      |> Nx.reshape({t, mels})

    out = App.Speaker.Fbank.compute(pcm)
    assert Nx.shape(out) == {t, mels}
    mad = out |> Nx.subtract(ref) |> Nx.abs() |> Nx.mean() |> Nx.to_number()
    assert mad < 0.05, "mean abs diff #{mad} too high"
  end

  # Locate the "data" subchunk's payload in a canonical RIFF/WAVE file, skipping
  # any other chunks (e.g. ffmpeg's "LIST"/"INFO") that precede it.
  defp pcm_data(<<"RIFF", _size::little-32, "WAVE", rest::binary>>), do: find_data(rest)

  defp find_data(<<"data", size::little-32, payload::binary-size(size), _rest::binary>>) do
    payload
  end

  defp find_data(<<_id::binary-size(4), size::little-32, rest::binary>>) do
    pad = rem(size, 2)
    <<_chunk::binary-size(size + pad), rest::binary>> = rest
    find_data(rest)
  end
end
