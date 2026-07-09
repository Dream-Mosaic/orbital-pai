// Mic capture → 16kHz mono PCM16 frames. We run the AudioContext AT 16kHz so the browser's
// (high-quality, anti-aliased) resampler does the downsampling; the worklet just converts
// float → PCM16. (The old version decimated by hand — nearest-sample, no low-pass — which
// aliased the audio and tanked STT accuracy.) Loaded from a Blob URL so it bundles with esbuild.
const WORKLET_SRC = `
class CaptureProcessor extends AudioWorkletProcessor {
  process(inputs) {
    const input = inputs[0]
    if (!input || !input[0]) return true
    const ch = input[0]
    const buf = new Int16Array(ch.length)
    for (let i = 0; i < ch.length; i++) {
      const s = Math.max(-1, Math.min(1, ch[i]))
      buf[i] = s < 0 ? s * 0x8000 : s * 0x7fff
    }
    this.port.postMessage(buf.buffer, [buf.buffer])
    return true
  }
}
registerProcessor("capture-processor", CaptureProcessor)
`

export async function startCapture(targetRate, onFrame) {
  const stream = await navigator.mediaDevices.getUserMedia({
    // autoGainControl normalizes quiet/distant speech (helps STT a lot).
    audio: {
      channelCount: 1,
      echoCancellation: true,
      noiseSuppression: true,
      autoGainControl: true,
    },
  })

  // If worklet load (or anything after the mic grant) fails, release the mic + context
  // so the mic indicator doesn't stay on with no way to stop it short of a reload.
  let ctx
  try {
    // Run the whole graph at the target rate -> the browser resamples the mic for us.
    const Ctx = window.AudioContext || window.webkitAudioContext
    ctx = new Ctx({ sampleRate: targetRate })
    if (ctx.sampleRate !== targetRate) {
      console.warn(`capture: requested ${targetRate}Hz, got ${ctx.sampleRate}Hz`)
    }

    const url = URL.createObjectURL(new Blob([WORKLET_SRC], { type: "application/javascript" }))
    await ctx.audioWorklet.addModule(url)
    URL.revokeObjectURL(url)

    const source = ctx.createMediaStreamSource(stream)
    const node = new AudioWorkletNode(ctx, "capture-processor")
    node.port.onmessage = (e) => onFrame(e.data)
    source.connect(node)

    // Visualization tap: observe the mic without affecting the worklet path.
    const analyser = ctx.createAnalyser()
    analyser.fftSize = 1024
    analyser.smoothingTimeConstant = 0.6
    source.connect(analyser)

    // The worklet only pulls audio if it has a sink; route through a muted gain.
    const sink = ctx.createGain()
    sink.gain.value = 0
    node.connect(sink).connect(ctx.destination)

    return {
      analyser,
      stop() {
        node.disconnect()
        source.disconnect()
        analyser.disconnect()
        for (const t of stream.getTracks()) t.stop()
        void ctx.close()
      },
    }
  } catch (err) {
    for (const t of stream.getTracks()) t.stop()
    if (ctx) void ctx.close()
    throw err
  }
}
