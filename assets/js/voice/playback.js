// Schedules incoming PCM16 chunks back-to-back via Web Audio. stop() cancels everything.
export class Playback {
  constructor(sampleRate) {
    this.sampleRate = sampleRate
    this.ctx = new (window.AudioContext || window.webkitAudioContext)()
    // Visualization tap: all playback flows through this analyser, then to the speakers.
    this.analyser = this.ctx.createAnalyser()
    this.analyser.fftSize = 1024
    this.analyser.smoothingTimeConstant = 0.6
    this.analyser.connect(this.ctx.destination)
    this.nextStart = 0
    this.active = new Set()
  }

  // True while audio is scheduled/playing (used to detect barge-in moments).
  get isPlaying() {
    return this.active.size > 0
  }

  // Browsers start the context suspended until a user gesture; call on the click.
  resume() {
    if (this.ctx.state === "suspended") this.ctx.resume()
  }

  enqueue(arrayBuffer) {
    // Int16Array needs an even byte length; drop a stray trailing byte defensively.
    const sampleCount = Math.floor(arrayBuffer.byteLength / 2)
    if (sampleCount === 0) return

    const i16 = new Int16Array(arrayBuffer, 0, sampleCount)
    const f32 = new Float32Array(i16.length)
    for (let i = 0; i < i16.length; i++) f32[i] = i16[i] / 0x8000

    const buffer = this.ctx.createBuffer(1, f32.length, this.sampleRate)
    buffer.copyToChannel(f32, 0)

    const src = this.ctx.createBufferSource()
    src.buffer = buffer
    src.connect(this.analyser)

    const startAt = Math.max(this.ctx.currentTime, this.nextStart)
    src.start(startAt)
    this.nextStart = startAt + buffer.duration

    this.active.add(src)
    src.onended = () => this.active.delete(src)
  }

  stop() {
    for (const src of this.active) {
      try {
        src.stop()
      } catch {
        /* already stopped */
      }
    }
    this.active.clear()
    this.nextStart = this.ctx.currentTime
  }

  // Release the AudioContext (browsers cap them ~6; hot-reload/remount leaks otherwise).
  close() {
    this.stop()
    return this.ctx.close()
  }
}
