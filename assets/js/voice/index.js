// The `Voice` LiveView hook: owns a dedicated socket/channel for binary audio + realtime
// text, completely off the LiveView render path. Mirrors the spike's mic→barge-in→playback
// loop, but over a Phoenix channel (`voice:<session_id>`) instead of a raw WebSocket.
import { Socket } from "phoenix"
import { startCapture } from "./capture"
import { Playback } from "./playback"
import { isKioskMode } from "./kiosk"
import { createOrb } from "./orb"
import { marked } from "marked"
import DOMPurify from "dompurify"

// Single newlines → <br> (the brain often uses them); CommonMark defaults otherwise.
marked.setOptions({ breaks: true })

// getUserMedia fails silently otherwise (power just bounces off). Map the common DOMException
// names to a plain-language caption so a stuck/blocked mic is obvious instead of a mystery —
// NotReadable/Abort = another app is holding the mic (a phone reboot frees it).
function micErrorMessage(err) {
  switch (err && err.name) {
    case "NotAllowedError":
    case "SecurityError":
      return "Microphone blocked — allow mic access for this site, then tap power again."
    case "NotReadableError":
    case "AbortError":
      return "Microphone is busy — close anything else using it (or restart the phone), then try again."
    case "NotFoundError":
      return "No microphone found — check your device's mic, then try again."
    default:
      return "Couldn't start the microphone — check permissions and try again."
  }
}

export const Voice = {
  // Chrome glow palette — mirrors orb.js's PAL; drives the Meridian surface recolor (the orb-light
  // bleed on main:has(#voice)). Keyed by orb state.
  ORB_PAL: {
    off: { glow: "#64748b", hi: "#4a5568", lo: "#1a1f27", rim: "#64748b", bleed: 0.22 },
    ambient: { glow: "#334155", hi: "#3a465a", lo: "#161b22", rim: "#475569", bleed: 0.30 },
    idle: { glow: "#6366f1", hi: "#6d7cff", lo: "#161b28", rim: "#8b93f7", bleed: 0.75 },
    listening: { glow: "#f59e0b", hi: "#f9b03a", lo: "#231c11", rim: "#fbbf24", bleed: 1.0 },
    speaking: { glow: "#10b981", hi: "#34d399", lo: "#10201a", rim: "#34d399", bleed: 0.95 },
    thinking: { glow: "#a855f7", hi: "#c084fc", lo: "#1c1230", rim: "#c084fc", bleed: 0.9 },
  },

  // Friendly labels for the live tool-call chip (addToolChip) — keyed by the tool name the
  // server announces (App.Tools registry names). Falls back to a humanized name if unlisted.
  TOOL_LABELS: {
    get_weather: "checking the weather",
    get_calendar_events: "checking your calendar",
    create_event: "adding to your calendar",
    create_reminder: "setting a reminder",
    list_reminders: "checking your reminders",
    search_email: "checking your email",
    read_email: "checking your email",
    send_email: "sending an email",
    recall_memory: "thinking back",
  },

  mounted() {
    this.sttSampleRate = parseInt(this.el.dataset.sttSampleRate || "16000", 10)
    this.ttsSampleRate = parseInt(this.el.dataset.ttsSampleRate || "44100", 10)
    this.sessionId = this.el.dataset.sessionId
    this.userToken = this.el.dataset.userToken
    this.playback = new Playback(this.ttsSampleRate)
    this.capture = null
    this.talking = false
    // Orb-state inputs — see resolveOrbState(): wakeLocked (screen asleep on the wall) and
    // turnState (what the current conversation turn is doing) are the two things that decide
    // what the orb shows; every writer below sets one of these then calls applyOrbState().
    this.wakeLocked = false
    this.turnState = "idle"
    // Kiosk = a wall tablet (?kiosk=1 / Fully Kiosk). We force hands-free, auto-start the mic, and
    // show a clock. Screen dimming/wake is handled by Fully Kiosk Browser, not in-app.
    this.kiosk = isKioskMode()

    if (this.kiosk) {
      this.kioskClock = document.createElement("div")
      this.kioskClock.id = "kiosk-clock"
      const tick = () => {
        this.kioskClock.textContent = new Date().toLocaleTimeString([], {
          hour: "numeric",
          minute: "2-digit",
        })
      }
      tick()
      this.kioskClockTimer = setInterval(tick, 1000)
      this.el.appendChild(this.kioskClock)
    }

    this.canvas = this.el.querySelector("#orb-canvas")
    this.captionEl = this.el.querySelector("#orb-caption")
    this.dotEl = document.querySelector("#state-dot")
    this.logEl = this.el.querySelector("#voice-log")
    this.abiEl = this.el.querySelector("#abi-toggle")
    this.pttToggleEl = this.el.querySelector("#ptt-toggle")
    this.pttHoldEl = this.el.querySelector("#ptt-hold")
    this.powerEl = this.el.querySelector("#power-btn")
    this.pttEnabled = false
    this.pttHeld = false

    const defaultAbi = this.el.dataset.defaultAbi === "true"
    this.defaultPtt = this.el.dataset.defaultPtt === "true"
    this.voiceActivation = this.el.dataset.voiceActivation === "true"
    this.assistantName = this.el.dataset.assistantName || "Henry"
    this.relockSeconds = parseInt(this.el.dataset.relockSeconds || "15", 10)
    this.handleEvent("set_relock", ({ seconds }) => {
      this.relockSeconds = seconds
      if (this.channel) this.channel.push("relock", { seconds })
    })
    this.handleEvent("clear_log", () => {
      this.clearThinking()
      this.logEl.innerHTML = ""
      this.brainEl = null
    })
    if (this.abiEl) this.abiEl.checked = defaultAbi
    if (this.pttToggleEl) this.pttToggleEl.checked = this.defaultPtt

    // Orb starts OFF (grey, still) until the user powers on.
    this.orb = createOrb(this.canvas)
    this.orb.start()
    this.applyOrbState()
    this.orb.setSources({ mic: null, playback: this.playback.analyser })
    this.setPower(false)
    this.setConnStatus("connecting")

    this.socket = new Socket("/socket", { params: { token: this.userToken } })
    // Header dot = server/connection status (not conversation state). The `[conn]` logs capture the
    // args these callbacks normally throw away, so a yellow flash leaves a reason in the console
    // (pair with the server's `[conn] ... channel terminate` line in companion.log).
    this.socket.onError((err) => {
      console.warn("[conn] socket error", err)
      this.setConnStatus("connecting")
    })
    this.socket.onClose((event) => {
      console.warn("[conn] socket close", event && event.code, event && event.reason)
      this.setConnStatus("offline")
    })
    this.socket.connect()
    // Topic suffix is ignored server-side; the auth token determines the session.
    this.channel = this.socket.channel(`voice:${this.sessionId}`, { kiosk: this.kiosk })
    this.channel.onError((reason) => {
      console.warn("[conn] channel error", reason)
      this.setConnStatus("connecting")
    })
    this.channel
      .join()
      .receive("ok", () => {
        console.info("[conn] connected")
        this.setConnStatus("connected")
        this.channel.push("allow_interruptions", { enabled: this.abiEl?.checked || false })
        this.channel.push("voice_activation", { enabled: this.kiosk && this.voiceActivation })
        this.channel.push("relock", { seconds: this.relockSeconds })
        if (this.kiosk) this.kioskAutoStart()
        if (this.defaultPtt && !this.kiosk) {
          // pre-set PTT mode without auto-starting the mic (no permission prompt on load;
          // the user powers on with the power button, which respects PTT mode)
          this.pttEnabled = true
          this.channel.push("ptt", { enabled: true })
          this.pttHoldEl.disabled = false
        }
      })
      .receive("error", (resp) => {
        console.warn("[conn] join error", resp)
        this.setConnStatus("connecting")
      })

    this.channel.on("partial", ({ text }) => this.setCaption(text))
    this.channel.on("locked", ({ locked }) => {
      this.setCaption(locked ? `Say “Wake up ${this.assistantName}”` : "")
      // Asleep on the wall = dim slate ambient orb (resolveOrbState), not whatever color the
      // last turn left the chrome on.
      this.wakeLocked = locked
      this.applyOrbState()
    })
    this.channel.on("transcript", ({ text }) => {
      this.setCaption("")
      this.addLine("you", text)
    })
    this.channel.on("speak_start", ({ source, text }) => {
      // Henry is now actually speaking this segment (reflex or brain) -> green + reactive to the
      // playback audio. Without this the orb sits in `thinking` (set at :start_brain) for the whole
      // answer, since no further turn-state event fires until :listening at the end.
      this.turnState = "speaking"
      this.applyOrbState()
      if (source === "brain") {
        this.clearThinking()
        this.resolveToolChips()
        // If we streamed deltas into a live brain line, snap it to the full markdown render now;
        // otherwise (e.g. the batch-brain fallback sends no deltas) render it fresh as today.
        if (this.brainEl) {
          this.renderBrainMarkdown(this.brainEl, text)
          this.brainEl = null
          this.logEl.scrollTop = this.logEl.scrollHeight
          return
        }
      }
      this.addLine(source, text)
    })
    this.channel.on("brain_delta", ({ delta }) => this.appendBrainDelta(delta))
    this.channel.on("tool_call", ({ name }) => this.addToolChip(name))
    // Latency HUD: one dim line per turn, updated as ttfa (reflex) then ttb (brain) land.
    this.channel.on("metrics", ({ ttfa, ttb }) => this.renderMetrics(ttfa, ttb))
    // Binary channel frame: payload IS the ArrayBuffer (no JSON envelope, no base64).
    this.channel.on("audio", (payload) => this.playback.enqueue(payload))
    this.channel.on("stop_playback", () => {
      const ms = this.playback.stop()
      this.channel.push("played", { ms })
    })
    this.channel.on("duck", () => this.playback.duck())
    this.channel.on("unduck", () => this.playback.unduck())
    // Turn state → Orb state. Half-duplex is enforced server-side (the policy ignores
    // any speech-endpoint mid-turn), so the mic keeps streaming — which keeps the STT
    // connection fed and healthy. "Allow interruptions" still controls barge-in.
    this.channel.on("speaking", () => {
      this.turnState = "speaking"
      this.applyOrbState()
    })
    this.channel.on("listening", () => {
      this.clearThinking()
      this.brainEl = null
      this.metricsEl = null
      // Drop any tool-call chips still unresolved (a turn barged mid-tool-call) — resolved ✓ chips
      // are already out of this array (resolveToolChips empties it) and stay in the log as the turn's story.
      for (const chip of this.toolChips || []) chip.remove()
      this.toolChips = []
      this.turnState = "listening"
      this.applyOrbState()
    })
    this.channel.on("thinking", () => {
      this.showThinking()
      this.turnState = "thinking"
      this.applyOrbState()
    })
    // Server state snapshot on every (re)bind: reset turn-scoped UI so a reconnect can't
    // leave a stale thinking line / wrong orb state from a turn that ended while offline.
    this.channel.on("state", ({ phase, locked }) => {
      this.clearThinking()
      this.brainEl = null
      // RE-ANCHOR: match the existing `locked` handler's exact caption wording (index.js).
      this.setCaption(locked ? `Say “Wake up ${this.assistantName}”` : "")
      // Re-anchor the wake lock from the snapshot too (a rebind after an offline relock carries
      // `locked` here but no separate `locked` push) so the ambient orb tint matches the caption.
      this.wakeLocked = locked
      if (this.talking) this.turnState = phase === "busy" ? "thinking" : this.pttHeld ? "listening" : "idle"
      this.applyOrbState()
    })
    // One-shot backfill after join. Only into an empty log — a rebind (wire pack) re-pushes
    // history and must not duplicate lines already on screen.
    this.channel.on("history", ({ turns }) => {
      if (!turns.length || this.logEl.querySelector(".voice-line")) return
      for (const t of turns) {
        if (t.you) this.addLine("you", t.you)
        if (t.assistant) this.addLine("brain", t.assistant)
      }
      const divider = document.createElement("div")
      divider.className = "voice-divider"
      divider.textContent = "— earlier —"
      this.logEl.appendChild(divider)
      this.logEl.scrollTop = this.logEl.scrollHeight
    })

    this.onPower = () => this.toggle()
    this.powerEl.addEventListener("click", this.onPower)

    this.onPttToggle = () => this.setPtt(this.pttToggleEl.checked)
    this.pttToggleEl.addEventListener("change", this.onPttToggle)

    this.onAbiToggle = () => this.channel.push("allow_interruptions", { enabled: this.abiEl.checked })
    this.abiEl.addEventListener("change", this.onAbiToggle)

    this.onHoldDown = (e) => { e.preventDefault(); this.pttPress() }
    this.onHoldUp = (e) => { e.preventDefault(); this.pttRelease() }
    this.pttHoldEl.addEventListener("pointerdown", this.onHoldDown)
    this.pttHoldEl.addEventListener("pointerup", this.onHoldUp)
    this.pttHoldEl.addEventListener("pointerleave", this.onHoldUp)

    this.onKeyDown = (e) => {
      if (this.pttEnabled && e.shiftKey && (e.key === "C" || e.key === "c") && !this.pttHeld) {
        e.preventDefault()
        this.pttPress()
      }
    }
    this.onKeyUp = (e) => {
      if (this.pttHeld && (e.key === "C" || e.key === "c" || e.key === "Shift")) this.pttRelease()
    }
    document.addEventListener("keydown", this.onKeyDown)
    document.addEventListener("keyup", this.onKeyUp)
  },

  destroyed() {
    if (this.kioskClockTimer) clearInterval(this.kioskClockTimer)
    this.stopTalking()
    if (this.orb) this.orb.stop()
    if (this.playback) this.playback.close()
    if (this.powerEl && this.onPower) this.powerEl.removeEventListener("click", this.onPower)
    if (this.abiEl && this.onAbiToggle) this.abiEl.removeEventListener("change", this.onAbiToggle)
    if (this.pttToggleEl && this.onPttToggle) this.pttToggleEl.removeEventListener("change", this.onPttToggle)
    if (this.pttHoldEl && this.onHoldDown) {
      this.pttHoldEl.removeEventListener("pointerdown", this.onHoldDown)
      this.pttHoldEl.removeEventListener("pointerup", this.onHoldUp)
      this.pttHoldEl.removeEventListener("pointerleave", this.onHoldUp)
    }
    document.removeEventListener("keydown", this.onKeyDown)
    document.removeEventListener("keyup", this.onKeyUp)
    if (this.channel) this.channel.leave()
    if (this.socket) this.socket.disconnect()
  },

  toggle() {
    if (this.talking) this.stopTalking()
    else this.startTalking()
  },

  async startTalking() {
    if (this.talking) return
    this.talking = true
    this.setPower(true)
    this.turnState = "idle"
    this.applyOrbState()
    this.setCaption("") // clear any prior mic-error message on retry
    this.playback.resume()
    try {
      this.capture = await startCapture(this.sttSampleRate, (pcm16) => {
        if (!this.pttEnabled || this.pttHeld) this.channel.push("audio", pcm16)
      })
      this.orb.setSources({ mic: this.capture.analyser, playback: this.playback.analyser })
    } catch (err) {
      this.talking = false
      this.setPower(false)
      this.applyOrbState() // talking is false -> resolves to "off"
      console.error("mic error:", err)
      this.setCaption(micErrorMessage(err))
    }
  },

  // Wall kiosks have no one to tap "power". Try to start the mic automatically (FKB pre-grants
  // mic permission + autoplay). If the browser blocks it without a gesture, show a one-time
  // full-screen overlay whose tap satisfies the gesture and starts capture.
  async kioskAutoStart() {
    await this.startTalking()
    if (this.talking) return // started cleanly (FKB or already-granted)
    if (document.getElementById("kiosk-tap")) return // overlay already up (e.g. a socket rejoin)

    const overlay = document.createElement("div")
    overlay.id = "kiosk-tap"
    overlay.textContent = `Tap to start ${this.assistantName}`
    overlay.addEventListener("click", async () => {
      await this.startTalking()
      if (this.talking) overlay.remove()
    })
    document.body.appendChild(overlay)
  },

  setPtt(enabled) {
    this.pttEnabled = enabled
    this.channel.push("ptt", { enabled })
    this.pttHoldEl.disabled = !enabled
    if (enabled && !this.talking) this.startTalking()
  },

  pttPress() {
    if (!this.pttEnabled || this.pttHeld) return
    this.pttHeld = true
    this.pttHoldEl.classList.add("ptt-held")
    this.turnState = "listening" // orange while held (or ambient if wake-locked)
    this.applyOrbState()
    this.channel.push("ptt_press", {})
  },

  pttRelease() {
    if (!this.pttHeld) return
    this.pttHeld = false
    this.pttHoldEl.classList.remove("ptt-held")
    this.turnState = "idle"
    this.applyOrbState()
    this.channel.push("ptt_release", {})
  },

  stopTalking() {
    this.talking = false
    this.setPower(false)
    this.setCaption("")
    this.clearThinking()
    this.applyOrbState() // talking is false -> resolves to "off"
    if (this.capture) {
      this.capture.stop()
      this.capture = null
    }
    this.orb.setSources({ mic: null, playback: this.playback.analyser })
    this.playback.stop()
  },

  // The orange "you" caption inside the Orb. Scales DOWN as it grows (mockup: "scales as it gets
  // longer") via a simple length→size step, so a long sentence still fits in the circle.
  setCaption(text) {
    if (!this.captionEl) return
    this.captionEl.textContent = text || ""
    const len = (text || "").length
    this.captionEl.style.fontSize = (len > 80 ? 0.95 : len > 40 ? 1.2 : 1.6) + "rem"
  },

  // Single source of truth for the orb: power off wins, then the wake lock (ambient = asleep
  // on the wall), then whatever the turn is doing. Every orb-state writer sets `this.talking`/
  // `this.wakeLocked`/`this.turnState` and calls applyOrbState() instead of setOrbState directly,
  // so a wake-locked kiosk always shows the slate ambient orb while idle/listening — a
  // speaking/thinking turn still finishes in its live color even if the lock lands mid-turn.
  resolveOrbState() {
    if (!this.talking) return "off"
    if (this.wakeLocked && (this.turnState === "idle" || this.turnState === "listening"))
      return "ambient"
    return this.turnState
  },

  applyOrbState() {
    this.setOrbState(this.resolveOrbState())
  },

  // Sets the orb's own animation state AND recolors the Meridian chrome (orb-light bleed) to match,
  // by writing the glow vars onto :root (document.documentElement) — matching the app.css defaults'
  // scope so the writes actually flow into #voice-shell via inheritance (see app.css comment).
  setOrbState(state) {
    if (this.orb) this.orb.setState(state)
    const p = this.ORB_PAL[state] || this.ORB_PAL.off
    const root = document.documentElement.style
    root.setProperty("--orb-glow", p.glow)
    root.setProperty("--orb-hi", p.hi)
    root.setProperty("--orb-lo", p.lo)
    root.setProperty("--orb-rim", p.rim)
    root.setProperty("--m-glow-o", String(p.bleed))
  },

  // The header dot reflects SERVER/connection status, NOT the conversation state.
  setConnStatus(status) {
    if (!this.dotEl) return
    const color =
      { connected: "bg-green-500", connecting: "bg-amber-500", offline: "bg-red-500" }[status] ||
      "bg-amber-500"
    this.dotEl.className = `size-2.5 rounded-full ${color}`
    this.dotEl.dataset.conn = status
  },

  // Power button: dim when off, green glow when on.
  setPower(on) {
    if (!this.powerEl) return
    this.powerEl.classList.toggle("text-success", on)
    this.powerEl.classList.toggle("opacity-50", !on)
    this.powerEl.setAttribute("aria-pressed", on ? "true" : "false")
  },

  // Output-side twin of the live caption: a faint, animated "thinking" line that fills the gap
  // after the reflex and before the brain's answer. Removed when the answer starts (brain
  // speak_start) or the turn ends (listening).
  showThinking() {
    if (!this.logEl || this.thinkingEl) return
    this.thinkingEl = document.createElement("div")
    this.thinkingEl.className = "voice-line who-brain thinking"
    const body = document.createElement("span")
    body.className = "body"
    this.thinkingEl.appendChild(body)
    this.logEl.appendChild(this.thinkingEl)
    let n = 1
    const render = () => {
      if (this.thinkingEl) body.textContent = `${this.assistantName}: thinking` + ".".repeat(n)
    }
    render()
    this.thinkingTimer = setInterval(() => {
      n = (n % 3) + 1
      render()
      this.logEl.scrollTop = this.logEl.scrollHeight
    }, 400)
    this.logEl.scrollTop = this.logEl.scrollHeight
  },

  clearThinking() {
    if (this.thinkingTimer) {
      clearInterval(this.thinkingTimer)
      this.thinkingTimer = null
    }
    if (this.thinkingEl) {
      this.thinkingEl.remove()
      this.thinkingEl = null
    }
  },

  // Visual twin of the audio tool-bridge filler: a live "⚙ checking your calendar…" chip per
  // tool call, appended to the log as the brain announces it. Resolved (…→ ✓) once the brain's
  // answer starts (first delta or speak_start), and cleared on the next :listening.
  addToolChip(name) {
    if (!this.logEl) return
    const chip = document.createElement("div")
    chip.className = "voice-tool-chip"
    chip.textContent = `⚙ ${this.TOOL_LABELS[name] || name.replace(/_/g, " ")}…`
    this.logEl.appendChild(chip)
    ;(this.toolChips ||= []).push(chip)
    this.logEl.scrollTop = this.logEl.scrollHeight
  },

  resolveToolChips() {
    for (const chip of this.toolChips || []) chip.textContent = chip.textContent.replace(/…$/, " ✓")
    this.toolChips = []
  },

  // Live brain caption: append raw text deltas to a single brain line as Gemini generates them.
  // Plaintext only (no markdown parse) so a half-open ** or code fence can't flicker mid-stream;
  // the final speak_start swaps it to the full markdown render. The first delta replaces the
  // thinking indicator line.
  appendBrainDelta(delta) {
    if (!this.logEl) return
    if (!this.brainEl) {
      this.resolveToolChips()
      this.clearThinking()
      const line = document.createElement("div")
      line.className = "voice-line who-brain"
      const label = document.createElement("span")
      label.className = "who"
      label.textContent = this.assistantName
      const body = document.createElement("span")
      body.className = "body voice-md"
      line.appendChild(label)
      line.appendChild(body)
      this.logEl.appendChild(line)
      this.brainEl = body
    }
    this.brainEl.textContent += delta
    this.logEl.scrollTop = this.logEl.scrollHeight
  },

  // Swap a brain line's content to the sanitized markdown render (matches addLine's brain path).
  renderBrainMarkdown(el, text) {
    try {
      el.innerHTML = DOMPurify.sanitize(marked.parse(text))
    } catch (_e) {
      el.textContent = text
    }
  },

  renderMetrics(ttfa, ttb) {
    if (!this.logEl) return
    if (!this.metricsEl) {
      this.metricsEl = document.createElement("div")
      this.metricsEl.className = "voice-metrics"
      this.logEl.appendChild(this.metricsEl)
    }
    const parts = []
    if (ttfa != null) parts.push(`⚡ ${(ttfa / 1000).toFixed(1)}s`)
    if (ttb != null) parts.push(`🧠 ${(ttb / 1000).toFixed(1)}s`)
    this.metricsEl.textContent = parts.join(" · ")
    this.logEl.scrollTop = this.logEl.scrollHeight
  },

  addLine(who, text) {
    if (!this.logEl) return
    const line = document.createElement("div")
    line.className = `voice-line who-${who}`
    const label = document.createElement("span")
    label.className = "who"
    label.textContent = who === "brain" || who === "reflex" ? this.assistantName : who
    const body = document.createElement("span")
    body.className = "body voice-md"
    if (who === "brain") this.renderBrainMarkdown(body, text)
    else body.textContent = text
    line.appendChild(label)
    line.appendChild(body)
    this.logEl.appendChild(line)
    this.logEl.scrollTop = this.logEl.scrollHeight
  },
}
