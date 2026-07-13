defmodule App.Speaker.Fbank do
  @moduledoc """
  Kaldi-compatible 80-dim log-mel fbank + utterance CMN, matching torchaudio
  `compliance.kaldi.fbank(num_mel_bins: 80, frame_length: 25, frame_shift: 10, dither: 0)`
  on int16-scaled samples — the exact features WeSpeaker embeds. Pure Nx, CPU.
  """

  @sr 16_000
  @frame 400
  @hop 160
  @nfft 512
  @nmels 80
  @low_hz 20.0
  @high_hz @sr / 2
  @preemph 0.97
  @log_floor 1.1921e-7

  @doc "PCM16 LE binary -> {t, 80} f32 tensor (log-mel + CMN). Needs >= 25ms of audio."
  def compute(pcm16) when is_binary(pcm16) and byte_size(pcm16) >= @frame * 2 do
    samples = pcm16 |> Nx.from_binary(:s16) |> Nx.as_type(:f32)
    n = div(Nx.size(samples) - @frame, @hop) + 1

    idx =
      Nx.iota({n, 1}) |> Nx.multiply(@hop) |> Nx.add(Nx.iota({1, @frame}))

    frames = Nx.take(samples, Nx.reshape(idx, {n * @frame})) |> Nx.reshape({n, @frame})
    # kaldi order: remove per-frame DC offset, pre-emphasis, povey window
    frames = Nx.subtract(frames, Nx.mean(frames, axes: [1], keep_axes: true))
    shifted = Nx.concatenate([frames[[.., 0..0]], frames[[.., 0..(@frame - 2)]]], axis: 1)
    frames = Nx.subtract(frames, Nx.multiply(shifted, @preemph))
    frames = Nx.multiply(frames, povey_window())

    padded = Nx.pad(frames, 0.0, [{0, 0, 0}, {0, @nfft - @frame, 0}])
    spec = Nx.fft(padded)
    bins = div(@nfft, 2) + 1
    power = spec |> Nx.abs() |> Nx.pow(2) |> Nx.slice_along_axis(0, bins, axis: 1)

    mel = power |> Nx.dot(mel_filterbank()) |> Nx.max(@log_floor) |> Nx.log()
    Nx.subtract(mel, Nx.mean(mel, axes: [0], keep_axes: true))
  end

  defp povey_window do
    n = Nx.iota({@frame}) |> Nx.as_type(:f32)
    two_pi = 2.0 * :math.pi()

    n
    |> Nx.multiply(two_pi / (@frame - 1))
    |> Nx.cos()
    |> Nx.multiply(-0.5)
    |> Nx.add(0.5)
    |> Nx.pow(0.85)
  end

  # {257, 80} triangular mel filterbank, kaldi mel scale (1127 * ln(1 + hz/700)).
  defp mel_filterbank do
    bins = div(@nfft, 2) + 1
    mel = fn hz -> 1127.0 * :math.log(1.0 + hz / 700.0) end
    lo = mel.(@low_hz)
    hi = mel.(@high_hz)
    centers = for m <- 0..(@nmels + 1), do: lo + (hi - lo) * m / (@nmels + 1)

    rows =
      for k <- 0..(bins - 1) do
        m_k = mel.(k * @sr / @nfft)

        for j <- 1..@nmels do
          {l, c, r} = {Enum.at(centers, j - 1), Enum.at(centers, j), Enum.at(centers, j + 1)}

          cond do
            m_k <= l or m_k >= r -> 0.0
            m_k <= c -> (m_k - l) / (c - l)
            true -> (r - m_k) / (r - c)
          end
        end
      end

    Nx.tensor(rows, type: :f32)
  end
end
