// One-shot webcam capture for "Henry, look at this". Opens the camera, grabs a single frame,
// downscales it to ~768px longest edge, JPEG-encodes it, and releases the camera immediately.
// Returns the base64 body (no `data:` prefix). Rejects if the camera is unavailable/denied.
// NEVER streams — the track is stopped before we return (in a finally, even on error).
const MAX_EDGE = 768
const JPEG_QUALITY = 0.7

export async function captureFrame() {
  const stream = await getCameraStream()

  try {
    const video = document.createElement("video")
    video.setAttribute("playsinline", "") // iOS: don't go fullscreen
    video.muted = true
    video.srcObject = stream
    await video.play()

    // Wait until we have frame dimensions (metadata) before drawing — but NEVER hang: race the
    // event against a short timeout so the `finally` (which stops the camera) always runs. If
    // dimensions are still unknown we fall back to default dims below.
    if (!video.videoWidth) {
      await new Promise((resolve) => {
        video.onloadedmetadata = () => resolve()
        setTimeout(resolve, 1500)
      })
    }

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
  }
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
