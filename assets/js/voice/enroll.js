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
    this.channel.join()
    this.recording = false
    this.handleEvent("enroll:record", ({ slot }) => this.record(slot))
  },

  async record(slot) {
    if (this.recording) return
    this.recording = true
    this.pushEvent("enroll_status", { slot, status: "recording" })
    this.channel.push("clip_reset", {})

    let capture
    try {
      capture = await startCapture(this.rate, (buf) => {
        if (this.recording) this.channel.push("audio", buf)
      })
    } catch (_err) {
      this.recording = false
      this.pushEvent("enroll_result", { slot, ok: false, reason: "mic_blocked" })
      return
    }

    setTimeout(() => {
      this.recording = false
      capture.stop()
      this.channel
        .push("clip_done", { slot })
        .receive("ok", () => this.pushEvent("enroll_result", { slot, ok: true }))
        .receive("error", ({ reason }) => this.pushEvent("enroll_result", { slot, ok: false, reason }))
        .receive("timeout", () => this.pushEvent("enroll_result", { slot, ok: false, reason: "timeout" }))
    }, CLIP_MS)
  },

  destroyed() {
    this.recording = false
    if (this.channel) this.channel.leave()
    if (this.socket) this.socket.disconnect()
  },
}
