# Phase 0 Spike Results

> **Not measured.** The cells below were never filled in; the spike was overtaken by the
> Ink-2 server-side barge-in design (server `turn.start`, confirmed by real words), which does
> not depend on a device AEC verdict. Treat every TBD as "unknown", not "passed". Re-run the
> procedure on a target tablet if open-mic barge-in on speaker output ever misbehaves.

## Binary Phoenix Channels from Dart
- Codec unit tests: TBD
- Live join to voice:henry: TBD
- Round-trip audio (up + down) confirmed: TBD

## Porcupine "Henry" wake word
| Device | Detections / 20 utterances | False accepts (10 min ambient) | Notes |
|---|---|---|---|
| Lenovo Tab (target) | TBD | TBD | |
| Pixel 8 (control) | TBD | TBD | |

## AEC measurement (Henry's own TTS leaking into the mic)
Procedure: see Task 7 checklist.
| Device | Self-interruptions / 2-min monologue (ABI on) | `partial` echo words while only Henry speaks | Verdict |
|---|---|---|---|
| Lenovo Tab (target) | TBD | TBD | TBD |
| Pixel 8 (control) | TBD | TBD | TBD |

## Decision
- Binary-Channels-from-Dart: TBD (sound / needs work)
- AEC on target: TBD (open-mic barge-in OK / must gate barge-in on wake word / needs software AEC)
