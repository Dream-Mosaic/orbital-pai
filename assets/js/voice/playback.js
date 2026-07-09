// Schedules incoming PCM16 chunks back-to-back via Web Audio. stop() cancels everything.
export class Playback {
  constructor(sampleRate) {
    this.sampleRate = sampleRate
    this.ctx = new (window.AudioContext || window.webkitAudioContext)()
    // Visualization tap: all playback flows through this analyser, then to the speakers.
    this.analyser = this.ctx.createAnalyser()
    this.analyser.fftSize = 1024
    this.analyser.smoothingTimeConstant = 0.6
    // Master gain: duck-then-decide dips this while an interruption is being classified.
    this.gain = this.ctx.createGain()
    this.gain.connect(this.ctx.destination)
    this.analyser.connect(this.gain)
    // Playback-progress tracking for the heard-fraction report.
    this.runStartedAt = null
    this.scheduledMs = 0
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
    if (this.active.size === 0 && this.ctx.currentTime > this.nextStart) {
      // idle gap: a new run starts now
      this.runStartedAt = null
      this.scheduledMs = 0
    }
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
    if (this.runStartedAt === null) this.runStartedAt = startAt
    this.scheduledMs += buffer.duration * 1000

    this.active.add(src)
    src.onended = () => this.active.delete(src)
  }

  // Cancels everything. Returns how many ms of the current run actually played.
  stop() {
    let playedMs = 0
    if (this.runStartedAt !== null) {
      playedMs = Math.max(0, Math.min((this.ctx.currentTime - this.runStartedAt) * 1000, this.scheduledMs))
    }
    for (const src of this.active) {
      try {
        src.stop()
      } catch {
        /* already stopped */
      }
    }
    this.active.clear()
    this.nextStart = this.ctx.currentTime
    this.runStartedAt = null
    this.scheduledMs = 0
    this.gain.gain.cancelScheduledValues(this.ctx.currentTime)
    this.gain.gain.setValueAtTime(1, this.ctx.currentTime)
    return Math.round(playedMs)
  }

  // Duck-then-decide: dip while the server classifies an interruption; restore on continue.
  duck() {
    const t = this.ctx.currentTime
    this.gain.gain.cancelScheduledValues(t)
    this.gain.gain.setTargetAtTime(0.35, t, 0.08)
  }

  unduck() {
    const t = this.ctx.currentTime
    this.gain.gain.cancelScheduledValues(t)
    this.gain.gain.setTargetAtTime(1, t, 0.15)
  }

  // Release the AudioContext (browsers cap them ~6; hot-reload/remount leaks otherwise).
  close() {
    this.stop()
    return this.ctx.close()
  }
}
