// Canvas Orb — a glass sphere core with soft glowing concentric halos that breathe, plus a live
// waveform drawn from the real audio. In the reactive states (listening/speaking) the smoothed
// loudness drives the glow, the breathing, the halo spread, and the animation speed, so the orb
// visibly responds to the voice. Pure view: feed it analysers + a state string; it runs its own
// requestAnimationFrame loop. Direction C, tuned in /dev/orb-lab.
//
// States: off = grey/frozen; ambient = dim slate/asleep (kiosk idle); idle = calm blue drift;
// listening = amber, reactive to YOUR mic; speaking = green, reactive to Henry's playback;
// thinking = steady violet cadence (not audio-reactive).

const HALOS = 3
const GLOW = 1.2
const BREATHE = 1.05
const CLARITY = 0.25

// Per-state palette: glow (halos + outer), hi/lo (sphere shading stops), rim (edge), wave (waveform).
const PAL = {
  off: { glow: "#64748b", hi: "#4a5568", lo: "#1a1f27", rim: "#64748b", wave: "#8b93a3" },
  ambient: { glow: "#334155", hi: "#3a465a", lo: "#161b22", rim: "#475569", wave: "#64748b" },
  idle: { glow: "#6366f1", hi: "#6d7cff", lo: "#161b28", rim: "#8b93f7", wave: "#a5b4fc" },
  listening: { glow: "#f59e0b", hi: "#f9b03a", lo: "#231c11", rim: "#fbbf24", wave: "#fcd34d" },
  speaking: { glow: "#10b981", hi: "#34d399", lo: "#10201a", rim: "#34d399", wave: "#6ee7b7" },
  thinking: { glow: "#a855f7", hi: "#c084fc", lo: "#1c1230", rim: "#c084fc", wave: "#d8b4fe" },
}

// Which states track live audio, and from which analyser.
const REACTIVE = { listening: "mic", speaking: "playback" }

export function createOrb(canvas) {
  const ctx = canvas.getContext("2d")
  let raf = null
  let last = null
  let stopped = false
  let state = "off"
  let mic = null
  let playback = null
  let micBuf = null
  let playBuf = null
  let t = 0
  let level = 0 // smoothed audio loudness, 0..1
  let box = { w: 256, h: 256 }

  function rgba(hex, a) {
    const n = parseInt(hex.slice(1), 16)
    return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`
  }

  // Size the backing store to the element's ACTUAL box (not a forced square). Drawing the orb
  // centered with R = min(w,h)*k then keeps it a circle regardless of the panel's aspect ratio
  // (kills the oval), and *dpr keeps it crisp. Re-sized whenever the CSS box changes.
  function size() {
    const dpr = window.devicePixelRatio || 1
    const w = canvas.clientWidth || 256
    const h = canvas.clientHeight || 256
    canvas.width = w * dpr
    canvas.height = h * dpr
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    box = { w, h }
  }

  // RMS loudness from an analyser's time-domain data (~0..1).
  function rms(analyser, buf) {
    if (!analyser || !buf) return 0
    analyser.getByteTimeDomainData(buf)
    let sum = 0
    for (let i = 0; i < buf.length; i++) {
      const v = (buf[i] - 128) / 128
      sum += v * v
    }
    return Math.min(1, Math.sqrt(sum / buf.length) * 3)
  }

  // Live waveform across the core, from the analyser's real time-domain data (tapered ends + glow).
  function drawWave(analyser, buf, color, cx, cy, halfW, amp) {
    if (!analyser || !buf) return
    analyser.getByteTimeDomainData(buf)
    const n = buf.length
    ctx.save()
    ctx.globalAlpha = 0.62
    ctx.shadowColor = color
    ctx.shadowBlur = 8
    ctx.lineWidth = 2
    ctx.strokeStyle = color
    ctx.beginPath()
    for (let i = 0; i < n; i++) {
      const x = cx - halfW + (i / (n - 1)) * (2 * halfW)
      const edge = Math.sin((i / (n - 1)) * Math.PI) // taper both ends
      const y = cy + ((buf[i] - 128) / 128) * amp * edge
      i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y)
    }
    ctx.stroke()
    ctx.restore()
  }

  function draw() {
    const w = canvas.clientWidth || 256
    const h = canvas.clientHeight || 256
    if (w !== box.w || h !== box.h) size() // keep backing store matched to the CSS box

    const pal = PAL[state] || PAL.off
    const off = state === "off"
    const cx = w / 2
    const cy = h / 2
    const R0 = Math.min(w, h) * 0.3
    const breathe = off ? 0 : BREATHE * (0.015 * Math.sin(t * 1.6) + level * 0.04)
    const R = R0 * (1 + breathe)

    ctx.clearRect(0, 0, w, h)

    // --- glowing concentric halos behind the core (soft, breathing, no dashes) ---
    if (!off) {
      ctx.save()
      for (let i = 0; i < HALOS; i++) {
        const f = HALOS > 1 ? i / (HALOS - 1) : 0
        const spread = R0 * (1.06 + i * 0.17 + level * 0.05)
        const rr = spread + Math.sin(t * 1.3 + i * 1.4) * R0 * 0.025 * BREATHE * (1 + level)
        ctx.shadowColor = pal.glow
        ctx.shadowBlur = 10 + 14 * GLOW
        ctx.beginPath()
        ctx.arc(cx, cy, rr, 0, Math.PI * 2)
        ctx.lineWidth = 2 - f
        ctx.strokeStyle = rgba(pal.glow, (0.42 - f * 0.3) * (0.6 + level * 0.6) * (0.5 + GLOW * 0.5))
        ctx.stroke()
      }
      ctx.restore()
    }

    // --- outer contact glow under the sphere ---
    if (!off) {
      ctx.save()
      ctx.shadowColor = pal.glow
      ctx.shadowBlur = 30 * GLOW * (0.6 + level)
      ctx.beginPath()
      ctx.arc(cx, cy, R, 0, Math.PI * 2)
      ctx.fillStyle = rgba(pal.glow, 0.06)
      ctx.fill()
      ctx.restore()
    }

    // --- glass core: spherical shading + translucency (halos glow through) ---
    ctx.save()
    ctx.beginPath()
    ctx.arc(cx, cy, R, 0, Math.PI * 2)
    ctx.clip()
    const base = ctx.createRadialGradient(cx - R * 0.32, cy - R * 0.38, R * 0.1, cx, cy, R * 1.05)
    base.addColorStop(0, rgba(pal.hi, off ? 0.5 : 0.9))
    base.addColorStop(0.6, rgba(pal.hi, (off ? 0.12 : 0.22) * (1 - CLARITY * 0.5)))
    base.addColorStop(1, rgba(pal.lo, off ? 0.85 : 0.78 + (1 - CLARITY) * 0.2))
    ctx.fillStyle = base
    ctx.fillRect(cx - R, cy - R, 2 * R, 2 * R)
    // bottom inner depth-shadow (weight)
    const sh = ctx.createRadialGradient(cx, cy + R * 0.55, R * 0.1, cx, cy + R * 0.2, R * 1.1)
    sh.addColorStop(0, rgba(pal.lo, 0.5))
    sh.addColorStop(1, "rgba(0,0,0,0)")
    ctx.fillStyle = sh
    ctx.fillRect(cx - R, cy - R, 2 * R, 2 * R)
    // live waveform from the reactive analyser (mic when listening, playback when speaking)
    if (!off) {
      const src = REACTIVE[state]
      if (src === "mic") drawWave(mic, micBuf, pal.wave, cx, cy + R * 0.06, R * 0.72, R * 0.24)
      else if (src === "playback") drawWave(playback, playBuf, pal.wave, cx, cy + R * 0.06, R * 0.72, R * 0.24)
    }
    ctx.restore()

    // --- specular highlight (glass) ---
    ctx.save()
    const sp = ctx.createRadialGradient(cx - R * 0.32, cy - R * 0.4, 0, cx - R * 0.32, cy - R * 0.4, R * 0.55)
    sp.addColorStop(0, `rgba(255,255,255,${0.5 * CLARITY + 0.15})`)
    sp.addColorStop(1, "rgba(255,255,255,0)")
    ctx.fillStyle = sp
    ctx.beginPath()
    ctx.ellipse(cx - R * 0.28, cy - R * 0.34, R * 0.44, R * 0.3, -0.5, 0, Math.PI * 2)
    ctx.fill()
    ctx.restore()

    // --- crisp rim light ---
    ctx.beginPath()
    ctx.arc(cx, cy, R, 0, Math.PI * 2)
    ctx.lineWidth = 1.5
    ctx.strokeStyle = rgba(pal.rim, off ? 0.4 : 0.9)
    ctx.stroke()
  }

  function frame(now) {
    if (!raf) return
    const dt = last == null ? 0.016 : Math.min(0.05, (now - last) / 1000)
    last = now

    // reactive states track the relevant voice (mic when listening, playback when speaking)
    const src = REACTIVE[state]
    const target = src === "mic" ? rms(mic, micBuf) : src === "playback" ? rms(playback, playBuf) : 0
    level += (target - level) * 0.2 // smooth

    // time advances the breathing/waveform; reactive states quicken with loudness; thinking keeps a
    // steady confident cadence; off is frozen.
    if (state !== "off") {
      const speed = state === "thinking" ? 1.4 : 1 + (src ? level * 1.4 : 0)
      t += dt * speed
    }

    draw()
    raf = requestAnimationFrame(frame)
  }

  return {
    setSources({ mic: m, playback: p } = {}) {
      mic = m || null
      playback = p || null
      micBuf = mic ? new Uint8Array(mic.fftSize) : null
      playBuf = playback ? new Uint8Array(playback.fftSize) : null
    },
    setState(s) {
      state = s
    },
    start() {
      stopped = false
      if (raf) return
      size()
      this.onResize = () => size()
      window.addEventListener("resize", this.onResize)
      this.onVisibility = () => {
        if (document.hidden) {
          if (raf) cancelAnimationFrame(raf)
          raf = null
        } else if (!stopped && !raf) {
          last = null // don't integrate the hidden gap
          raf = requestAnimationFrame(frame)
        }
      }
      document.addEventListener("visibilitychange", this.onVisibility)
      raf = requestAnimationFrame(frame)
    },
    stop() {
      stopped = true
      if (raf) cancelAnimationFrame(raf)
      raf = null
      if (this.onResize) window.removeEventListener("resize", this.onResize)
      if (this.onVisibility) document.removeEventListener("visibilitychange", this.onVisibility)
    },
  }
}
