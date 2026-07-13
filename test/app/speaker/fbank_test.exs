defmodule App.Speaker.FbankTest do
  use ExUnit.Case, async: true

  @dir "test/support/fixtures/speaker"

  test "matches the torchaudio kaldi fbank reference (mean abs diff < 0.05)" do
    # ffmpeg wrote a LIST/INFO chunk before "data" here, so a fixed 44-byte
    # strip grabs chunk metadata instead of samples — the shared fixture reader
    # walks the RIFF chunks to find the real "data" payload instead.
    pcm = App.Test.SpeakerFixtures.read_pcm("a1.wav")

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
end
