// One-shot webcam capture for "Henry, look at this". Opens the camera, waits past the BLACK
// warm-up frames (the first frames out of getUserMedia are black until the sensor exposes) by
// actually checking the pixels, grabs a real frame, downscales to ~768px longest edge, JPEG-encodes
// it, and releases the camera immediately. Returns the base64 body (no `data:` prefix). Rejects if
// the camera is unavailable/denied. NEVER streams — the track is stopped in a `finally`, even on error.
const MAX_EDGE = 768
const JPEG_QUALITY = 0.7
// Below this mean luminance (0–255) the frame is treated as a not-yet-exposed black warm-up frame.
const BLACK_LUMA = 10
// How long to keep re-sampling for a non-black frame before giving up and sending what we have.
const NONBLACK_DEADLINE_MS = 2500
// Ceiling on the "wait for video dimensions" step so we never hang.
const DIMS_TIMEOUT_MS = 1500

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

export async function captureFrame() {
  const stream = await getCameraStream()

  // Keep the element minimally on-page (hidden) — some browsers won't paint frames for a fully
  // detached/hidden <video>, which yields a black canvas.
  const video = document.createElement("video")
  video.setAttribute("playsinline", "") // iOS: don't go fullscreen
  video.muted = true
  video.srcObject = stream
  video.style.cssText =
    "position:fixed;left:0;top:0;width:1px;height:1px;opacity:0;pointer-events:none"
  document.body.appendChild(video)

  try {
    await video.play()
    await waitForDimensions(video)
    return await grabNonBlackFrame(video)
  } finally {
    for (const t of stream.getTracks()) t.stop()
    video.srcObject = null
    video.remove()
  }
}

// Draw the video to a downscaled canvas, RE-SAMPLING until the frame isn't black (the sensor has
// warmed up) or a deadline passes. Waiting only for `loadedmetadata`/`canplay` isn't enough — the
// pixels can still be black for a few hundred ms after; here we look at the actual luminance.
async function grabNonBlackFrame(video) {
  const w = video.videoWidth || 640
  const h = video.videoHeight || 480
  const scale = Math.min(1, MAX_EDGE / Math.max(w, h))
  const cw = Math.max(1, Math.round(w * scale))
  const ch = Math.max(1, Math.round(h * scale))

  const canvas = document.createElement("canvas")
  canvas.width = cw
  canvas.height = ch
  const ctx = canvas.getContext("2d")

  const deadline = Date.now() + NONBLACK_DEADLINE_MS
  while (true) {
    ctx.drawImage(video, 0, 0, cw, ch)
    if (!isBlack(ctx, cw, ch) || Date.now() >= deadline) break
    await sleep(120)
  }

  const dataUrl = canvas.toDataURL("image/jpeg", JPEG_QUALITY)
  return dataUrl.replace(/^data:image\/jpeg;base64,/, "")
}

// Mean luminance of a sparse sample of the canvas < BLACK_LUMA. getUserMedia frames are same-origin
// so the canvas isn't tainted (getImageData is allowed); if it ever throws, treat as "not black" so
// we never loop forever.
function isBlack(ctx, w, h) {
  try {
    const { data } = ctx.getImageData(0, 0, w, h)
    const stride = Math.max(1, Math.floor((w * h) / 500)) * 4 // ~500 samples
    let sum = 0
    let n = 0
    for (let i = 0; i + 2 < data.length; i += stride) {
      sum += 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2]
      n++
    }
    return n > 0 && sum / n < BLACK_LUMA
  } catch (_e) {
    return false
  }
}

// Wait until the video reports frame dimensions (needed before we can draw), capped so we never hang.
function waitForDimensions(video) {
  return new Promise((resolve) => {
    if (video.videoWidth) return resolve()
    let done = false
    const finish = () => {
      if (!done) {
        done = true
        resolve()
      }
    }
    video.onloadedmetadata = () => finish()
    if (typeof video.requestVideoFrameCallback === "function") {
      video.requestVideoFrameCallback(() => finish())
    }
    setTimeout(finish, DIMS_TIMEOUT_MS)
  })
}

// Prefer the rear camera, but fall back to any camera. Some webviews (notably Fully Kiosk on the
// wall) reject the facingMode constraint outright instead of treating `ideal` as a soft preference;
// the plain `{video: true}` retry works around that. If THAT rejects too, its error (the real
// access/no-camera reason) propagates to the caller and is reported to the server for the log.
async function getCameraStream() {
  try {
    return await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: "environment" } } })
  } catch (_e) {
    return await navigator.mediaDevices.getUserMedia({ video: true })
  }
}
