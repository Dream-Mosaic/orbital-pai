import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../camera/camera_service.dart';

/// Where a capture is, as the orb draws it ([CameraFace]).
enum CameraPhase {
  /// The 3·2·1: the camera opening and then showing what it sees.
  countdown,

  /// The countdown ran out and the picture is being taken: the white flash.
  shutter,

  /// The picture, frozen in the glass while Henry thinks about it.
  frozen,
}

/// One "Henry, look at this" as the UI sees it. Immutable; the relay replaces
/// it whole on every step, so a frame can never draw half of a transition.
@immutable
class CameraShot {
  const CameraShot({
    required this.id,
    required this.phase,
    this.count = 0,
    this.previewing = false,
    this.snapshot,
  });

  /// The server's `capture_id` (the `camera_capture` push's `id`).
  final String id;
  final CameraPhase phase;

  /// The digit showing during [CameraPhase.countdown] (3, 2, 1); 0 = none.
  final int count;

  /// Whether the camera is open and its viewfinder worth drawing.
  final bool previewing;

  /// The JPEG that went to the server; set in [CameraPhase.frozen].
  final Uint8List? snapshot;

  CameraShot copyWith({CameraPhase? phase, int? count, bool? previewing}) =>
      CameraShot(
        id: id,
        phase: phase ?? this.phase,
        count: count ?? this.count,
        previewing: previewing ?? this.previewing,
        snapshot: snapshot,
      );
}

/// How long each step may take. Injectable so tests run in milliseconds.
@immutable
class CameraTimings {
  const CameraTimings({
    this.hold = const Duration(seconds: 20),
    this.openTimeout = const Duration(seconds: 12),
    this.captureTimeout = const Duration(seconds: 6),
    this.maxCountdown = const Duration(seconds: 5),
  });

  /// The frozen snapshot's stay when no `camera_done` comes for it (spec §1).
  final Duration hold;

  /// The camera opening, permission prompt included. As long as the server
  /// waits for a frame: past that, nobody is listening for this one.
  final Duration openTimeout;

  /// The shutter.
  final Duration captureTimeout;

  /// A ceiling on the server's `countdown_ms`.
  final Duration maxCountdown;
}

/// "Henry, look at this" on the device (spec 2026-10-23, game night §1): the
/// `camera_capture` → `camera_frame` → `camera_done` exchange, the countdown,
/// and the snapshots the photo cards show.
///
/// Owned by [VoiceController], which routes the two pushes here and draws
/// [shot]. Everything it says goes out through [_push] (the joined
/// `voice:henry` channel, or nowhere), and every change it makes is announced
/// through [_changed].
class CameraRelay {
  CameraRelay({
    required CameraService service,
    required void Function(String event, Map<String, dynamic> payload) push,
    required VoidCallback changed,
    void Function(String line)? log,
    this.timings = const CameraTimings(),
  })  : _service = service,
        _push = push,
        _changed = changed,
        _log = log ?? _noLog;

  static void _noLog(String _) {}

  final CameraService _service;
  final void Function(String event, Map<String, dynamic> payload) _push;
  final VoidCallback _changed;
  final void Function(String line) _log;
  final CameraTimings timings;

  /// How many snapshots stay in memory for the photo cards (oldest go first).
  static const int keep = 10;

  CameraShot? _shot;

  /// What the orb shows: null when no capture is live.
  CameraShot? get shot => _shot;

  /// The capture in flight (opening, counting down, shooting): the token every
  /// async continuation checks it still holds. Null once the frame is out —
  /// a frozen snapshot is not "busy".
  _Run? _run;

  /// Whether a capture is in flight (a second request now is refused).
  bool get busy => _run != null;

  Timer? _hold;
  bool _disposed = false;

  final Map<String, Uint8List> _snapshots = <String, Uint8List>{};

  /// The snapshot taken for [captureId] this session, or null (evicted,
  /// another device's, a history replay).
  Uint8List? snapshotFor(String captureId) => _snapshots[captureId];

  /// The server's `camera_capture` {id, facing, countdown_ms}.
  void capture(Map<String, dynamic> p) {
    if (_disposed) return;
    final id = p['id'];
    // Nothing to answer to: the server cannot be waiting on an id it never sent.
    if (id is! String || id.isEmpty) return;
    if (_run != null) {
      _log('camera: busy, refused $id');
      _push('camera_frame', {'id': id, 'error': CameraFailure.failed});
      return;
    }
    final facing = p['facing'] == 'front' ? 'front' : 'back';
    final ms = (p['countdown_ms'] as num?)?.toInt() ?? 2400;
    final countdown = Duration(
        milliseconds: ms.clamp(0, timings.maxCountdown.inMilliseconds));

    // A new capture replaces a snapshot still frozen from the last one.
    _hold?.cancel();
    _hold = null;
    final run = _Run(id, countdown);
    _run = run;
    _shot = CameraShot(
      id: id,
      phase: CameraPhase.countdown,
      count: countdown > Duration.zero ? 3 : 0,
    );
    _log('camera: capture $id ($facing, ${countdown.inMilliseconds} ms)');
    _changed();

    run.opened = _service
        .open(facing: facing)
        .timeout(timings.openTimeout,
            onTimeout: () => throw const CameraFailure(
                CameraFailure.failed, 'the camera did not open'));
    run.opened.then((_) {
      if (!identical(_run, run)) return;
      _shot = _shot?.copyWith(previewing: true);
      _changed();
    }, onError: (Object e) => _fail(run, e));
    _countdown(run);
  }

  /// The server's `camera_done` {id}: it has what it needed from [id].
  void done(Map<String, dynamic> p) {
    final id = p['id'];
    if (id is! String || _shot?.id != id) return;
    // Still counting down: the server gave up on this one, so it gets nothing.
    if (_run != null) {
      _log('camera: done before the frame, $id dropped');
      _abortRun();
    }
    _release(id);
  }

  /// The channel went down: a capture in flight has nobody to answer, so it
  /// stops and the camera closes. A frozen snapshot stays out its hold.
  void abort() {
    if (_run == null) return;
    _log('camera: aborted');
    _abortRun();
    _shot = null;
    _changed();
  }

  void dispose() {
    _disposed = true;
    _hold?.cancel();
    _hold = null;
    final had = _run != null;
    _run?.cancel();
    _run = null;
    _shot = null;
    if (had) unawaited(_close());
  }

  // ---- the run ----

  /// The 3·2·1: [CameraShot.count] steps down in thirds of the countdown,
  /// then the shutter. No countdown: straight to the shutter.
  void _countdown(_Run run) {
    if (run.countdown <= Duration.zero) {
      unawaited(_shoot(run));
      return;
    }
    _step(run, run.countdown ~/ 3);
  }

  void _step(_Run run, Duration step) {
    run.timer = Timer(step, () {
      if (!identical(_run, run)) return;
      final next = (_shot?.count ?? 1) - 1;
      if (next <= 0) {
        unawaited(_shoot(run));
        return;
      }
      _shot = _shot?.copyWith(count: next);
      _changed();
      _step(run, step);
    });
  }

  Future<void> _shoot(_Run run) async {
    if (!identical(_run, run)) return;
    _shot = _shot?.copyWith(phase: CameraPhase.shutter, count: 0);
    _changed();
    final Uint8List bytes;
    try {
      await run.opened;
      if (!identical(_run, run)) return;
      bytes = await _service.capture().timeout(timings.captureTimeout,
          onTimeout: () => throw const CameraFailure(
              CameraFailure.failed, 'the shutter did not answer'));
    } catch (e) {
      _fail(run, e);
      return;
    }
    if (!identical(_run, run)) return;
    _run = null;
    // The picture is in hand: the camera has nothing left to do.
    unawaited(_close());
    _remember(run.id, bytes);
    _push('camera_frame', {'id': run.id, 'jpeg': base64Encode(bytes)});
    _log('camera: sent ${run.id} (${bytes.length ~/ 1024} KB)');
    _shot = CameraShot(id: run.id, phase: CameraPhase.frozen, snapshot: bytes);
    _hold = Timer(timings.hold, () => _release(run.id));
    _changed();
  }

  /// [run] failed: answer with the error, close the camera, clear the glass.
  void _fail(_Run run, Object e) {
    if (_disposed || !identical(_run, run)) return;
    final code = e is CameraFailure ? e.code : CameraFailure.failed;
    _log('camera: ${run.id} failed: $e');
    _abortRun();
    _push('camera_frame', {'id': run.id, 'error': code});
    _shot = null;
    _changed();
  }

  void _abortRun() {
    _run?.cancel();
    _run = null;
    unawaited(_close());
  }

  void _release(String id) {
    if (_shot?.id != id) return;
    _hold?.cancel();
    _hold = null;
    _shot = null;
    if (!_disposed) _changed();
  }

  void _remember(String id, Uint8List bytes) {
    _snapshots.remove(id);
    _snapshots[id] = bytes;
    while (_snapshots.length > keep) {
      _snapshots.remove(_snapshots.keys.first);
    }
  }

  Future<void> _close() async {
    try {
      await _service.close();
    } catch (e) {
      _log('camera: close failed: $e');
    }
  }
}

class _Run {
  _Run(this.id, this.countdown);

  final String id;
  final Duration countdown;
  late Future<void> opened;
  Timer? timer;

  void cancel() {
    timer?.cancel();
    timer = null;
  }
}
