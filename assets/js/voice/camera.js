// One-shot webcam capture for "Henry, look at this". Opens the camera, waits for a REAL painted
// frame (not just metadata — the first frames after getUserMedia are black until the sensor warms
// up), grabs it, downscales to ~768px longest edge, JPEG-encodes it, and releases the camera
// immediately. Returns the base64 body (no `data:` prefix). Rejects if the camera is
// unavailable/denied. NEVER streams — the track is stopped in a `finally`, even on error.
const MAX_EDGE = 768
const JPEG_QUALITY = 0.7
// After the first real frame, let auto-exposure catch up so we don't grab a dark/underexposed shot.
const SETTLE_MS = 400
// Hard ceiling on the wait-for-a-frame step so we never hang (the `finally` always releases the camera).
const FRAME_TIMEOUT_MS = 2500

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
    await waitForFrame(video)

    const w = video.videoWidth || 640
    const h = video.videoHeight || 480
    const scale = Math.min(1, MAX_EDGE / Math.max(w, h))
    const cw = Math.max(1, Math.round(w * scale))
    const ch = Math.max(1, Math.round(h * scale))

    const canvas = document.createElement("canvas")
    canvas.width = cw
    canvas.height = ch
    canvas.getContext("2d").drawImage(video, 0, 0, cw, ch)

    const dataUrl = canvas.toDataURL("image/jpeg", JPEG_QUALITY)
    return dataUrl.replace(/^data:image\/jpeg;base64,/, "")
  } finally {
    for (const t of stream.getTracks()) t.stop()
    video.srcObject = null
    video.remove()
  }
}

// Wait for a real, painted camera frame before we draw. Waiting only for `loadedmetadata`
// (dimensions) grabs a BLACK frame — the pixels aren't ready yet. Prefer requestVideoFrameCallback
// (fires when a frame is actually presented); fall back to `canplay` (readyState >= HAVE_CURRENT_DATA).
// Then a short settle for auto-exposure. Everything is capped so we never hang.
function waitForFrame(video) {
  return new Promise((resolve) => {
    let done = false
    const finish = () => {
      if (!done) {
        done = true
        resolve()
      }
    }
    const settleThenFinish = () => setTimeout(finish, SETTLE_MS)

    if (typeof video.requestVideoFrameCallback === "function") {
      video.requestVideoFrameCallback(() => settleThenFinish())
    } else if (video.readyState >= 2) {
      settleThenFinish()
    } else {
      video.oncanplay = () => settleThenFinish()
    }

    setTimeout(finish, FRAME_TIMEOUT_MS) // hard ceiling — never hang
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
