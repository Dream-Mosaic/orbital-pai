/// 1a stub. Behavior gating (launcher, foreground service, keep-screen-on)
/// is deferred to Milestone 1b; both devices run in `companion` foreground mode.
enum DeviceMode { kiosk, companion }

/// Hard-coded for 1a. 1b will resolve this from device config / launch intent.
const DeviceMode kDeviceMode = DeviceMode.companion;
