"""Generate parity references for the Elixir Ortex/Fbank implementation.
Writes: fbank_ref.bin (f32 LE, row-major [T,80]) + fbank_ref_shape.txt, emb_ref.bin (f32 LE),
and prints same/different-speaker cosines -> provisional threshold."""
import numpy as np, soundfile as sf, torch, torchaudio.compliance.kaldi as kaldi, onnxruntime as ort

MODEL = "../../../../priv/models/speaker_ecapa.onnx"

def fbank(path):
    wav, sr = sf.read(path, dtype="int16")
    assert sr == 16000, path
    t = torch.from_numpy(wav.astype(np.float32)).unsqueeze(0)  # int16 scale, as wespeaker does
    f = kaldi.fbank(t, num_mel_bins=80, frame_length=25, frame_shift=10, dither=0.0,
                    sample_frequency=16000)
    return (f - f.mean(dim=0, keepdim=True)).numpy()  # utterance CMN

sess = ort.InferenceSession(MODEL)
iname = sess.get_inputs()[0].name

def embed(path):
    f = fbank(path)
    e = sess.run(None, {iname: f[None, :, :]})[0][0]
    return e / np.linalg.norm(e)

f_a1 = fbank("a1.wav")
f_a1.astype("<f4").tofile("fbank_ref.bin")
open("fbank_ref_shape.txt", "w").write(f"{f_a1.shape[0]} {f_a1.shape[1]}")
e = {n: embed(f"{n}.wav") for n in ["a1", "a2", "b1", "b2"]}
e["a1"].astype("<f4").tofile("emb_ref.bin")
same = [float(e["a1"] @ e["a2"]), float(e["b1"] @ e["b2"])]
diff = [float(e["a1"] @ e["b1"]), float(e["a1"] @ e["b2"]), float(e["a2"] @ e["b1"])]
print("same-speaker cosines:", same, "\ndiff-speaker cosines:", diff)
print("provisional threshold (midpoint):", (min(same) + max(diff)) / 2)
