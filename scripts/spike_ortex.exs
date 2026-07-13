# GO/NO-GO: can Ortex load + run the model and reproduce the Python embedding?
path = "priv/models/speaker_ecapa.onnx"
model = Ortex.load(path)
[t, mels] =
  "test/support/fixtures/speaker/fbank_ref_shape.txt"
  |> File.read!() |> String.split() |> Enum.map(&String.to_integer/1)

feats =
  "test/support/fixtures/speaker/fbank_ref.bin"
  |> File.read!() |> Nx.from_binary(:f32) |> Nx.reshape({1, t, mels})

{out} = Ortex.run(model, feats)
emb = out[0] |> Nx.to_flat_list()
norm = :math.sqrt(Enum.reduce(emb, 0.0, &(&2 + &1 * &1)))
emb = Enum.map(emb, &(&1 / norm))
ref = "test/support/fixtures/speaker/emb_ref.bin" |> File.read!() |> Nx.from_binary(:f32) |> Nx.to_flat_list()
cos = Enum.zip(emb, ref) |> Enum.reduce(0.0, fn {a, b}, s -> s + a * b end)
IO.puts("cosine vs python reference: #{cos}")
if cos > 0.99, do: IO.puts("GO"), else: IO.puts("NO-GO")
