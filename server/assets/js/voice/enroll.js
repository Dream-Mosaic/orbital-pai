// VoiceEnroll hook: records one ~10s enrollment clip per prompt slot through the SAME
// capture path as live turns (same getUserMedia constraints -> same audio domain as the
// voiceprint will see at runtime), streaming PCM16 to the enroll channel.
import { Socket } from "phoenix"
import { startCapture } from "./capture"

const CLIP_MS = 10_000

export const VoiceEnroll = {
  mounted() {
    this.userId = this.el.dataset.user
    this.rate = parseInt(this.el.dataset.rate, 10) || 16000
    this.socket = new Socket("/socket", { params: { token: this.el.dataset.token } })
    this.socket.connect()
    this.channel = this.socket.channel(`enroll:${this.userId}`, {})
    this.channel
      .join()
      .receive("error", (reason) => console.error("[VoiceEnroll] enroll channel join failed", reason))
    this.recording = false
    this.capture = null
    this.clipTimer = null
    this.handleEvent("enroll:record", ({ slot }) => this.record(slot))
  },

  async record(slot) {
    if (this.recording) return
    this.recording = true
    this.pushEvent("enroll_status", { slot, status: "recording" })
    this.channel.push("clip_reset", {})

    try {
      this.capture = await startCapture(this.rate, (buf) => {
        if (this.recording) this.channel.push("audio", buf)
      })
    } catch (_err) {
      this.recording = false
      this.pushEvent("enroll_result", { slot, ok: false, reason: "mic_blocked" })
      return
    }

    this.clipTimer = setTimeout(() => {
      this.clipTimer = null
      this.stopCapture()
      this.channel
        .push("clip_done", { slot })
        .receive("ok", () => this.pushEvent("enroll_result", { slot, ok: true }))
        .receive("error", ({ reason }) => this.pushEvent("enroll_result", { slot, ok: false, reason }))
        .receive("timeout", () => this.pushEvent("enroll_result", { slot, ok: false, reason: "timeout" }))
    }, CLIP_MS)
  },

  // Stop and release the mic stream / AudioContext. Idempotent — safe to call more than once
  // (normal end-of-clip and a mid-recording hook teardown both route through here).
  stopCapture() {
    this.recording = false
    if (this.capture) {
      this.capture.stop()
      this.capture = null
    }
  },

  destroyed() {
    if (this.clipTimer) clearTimeout(this.clipTimer)
    this.stopCapture()
    if (this.channel) this.channel.leave()
    if (this.socket) this.socket.disconnect()
  },
}
