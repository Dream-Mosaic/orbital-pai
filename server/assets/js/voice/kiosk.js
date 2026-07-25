// Kiosk detection for the wall tablet. Screen dimming/sleep + wake are handled by Fully Kiosk
// Browser (its screensaver + motion detection), NOT in-app — the old in-app wake-gate/dimming was
// removed. Kiosk mode here only forces hands-free, auto-starts the mic, and shows a clock.

// Kiosk mode is on when launched as ?kiosk=1 OR when the Fully Kiosk bridge is present.
export function isKioskMode() {
  const param = new URLSearchParams(window.location.search).get("kiosk")
  return param === "1" || typeof window.fully !== "undefined"
}
