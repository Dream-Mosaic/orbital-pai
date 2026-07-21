// Porcupine "Henry" wake-word spike screen (Milestone 1a, Task 7 — code
// portion only; see `.superpowers/sdd/task-7-brief.md`).
//
// DEFERRED to the on-device session (NOT part of this commit):
//   - Training the "Henry" .ppn wake-word model in the Picovoice Console and
//     placing it at `native/assets/henry.ppn` (gitignored; the file does not
//     exist yet).
//   - Registering `assets/henry.ppn` in `pubspec.yaml`'s `flutter: assets:`
//     block — adding that entry before the file exists breaks
//     `flutter build apk`, so it is intentionally left out for now.
//   - Filling in the real Picovoice AccessKey in `config.dart`
//     (`kPicovoiceAccessKey` is still the Task 1 placeholder).
//   - The on-device wake-word hit-rate smoke and AEC self-trigger/leak
//     measurement (task-7-brief.md Steps 5-7, recorded in
//     `docs/phase0-results.md`).
//
// This screen loads `'assets/henry.ppn'` via `rootBundle` at runtime, which
// compiles and analyzes cleanly without the asset present; it only fails at
// runtime (inside `_start()`, caught and surfaced via `_status`) until the
// device session supplies the trained model + AccessKey.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:porcupine_flutter/porcupine.dart';
import '../audio/mic_capture.dart';
import '../config.dart';

class PorcupineSpikeScreen extends StatefulWidget {
  const PorcupineSpikeScreen({super.key});
  @override
  State<PorcupineSpikeScreen> createState() => _PorcupineSpikeScreenState();
}

class _PorcupineSpikeScreenState extends State<PorcupineSpikeScreen> {
  final MicCapture _mic = MicCapture();
  Porcupine? _porcupine;
  StreamSubscription<Uint8List>? _sub;
  final List<int> _pending = <int>[]; // int16 samples awaiting a full frame
  bool _busy = false; // serializes frame processing across audio callbacks
  int _detections = 0;
  String _status = 'idle';

  Future<String> _copyAssetToFile(String asset, String name) async {
    final bytes = await rootBundle.load(asset);
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    return f.path;
  }

  Future<void> _start() async {
    try {
      final ppnPath = await _copyAssetToFile('assets/henry.ppn', 'henry.ppn');
      _porcupine = await Porcupine.fromKeywordPaths(
        kPicovoiceAccessKey,
        [ppnPath],
      );
      final frameLen = _porcupine!.frameLength; // expect 512
      final stream = await _mic.start();
      setState(() => _status = 'listening (frameLength=$frameLen, '
          'sampleRate=${_porcupine!.sampleRate})');
      _sub = stream.listen((chunk) => _onAudio(chunk, frameLen));
    } catch (e) {
      setState(() => _status = 'start failed: $e');
    }
  }

  // NOTE (porcupine_flutter 3.0.6 adaptation): `Porcupine.process` is
  // `Future<int> process(List<int>? frame)` — async, and returns a
  // non-nullable `int` (-1 for "no detection", not `null`) — unlike the
  // synchronous `int?` the original draft assumed. Making this callback
  // `async` means a new audio chunk can arrive (and append to `_pending`)
  // while a previous frame's `process()` call is still awaiting its
  // MethodChannel round trip. `_busy` serializes the actual processing loop
  // to a single in-flight call at a time; a chunk that arrives mid-process
  // just enqueues into `_pending` and returns immediately — the active loop
  // picks it up on its next iteration, so no frames are lost or double
  // processed.
  Future<void> _onAudio(Uint8List chunk, int frameLen) async {
    final bd = ByteData.sublistView(chunk);
    for (var i = 0; i + 1 < chunk.length; i += 2) {
      _pending.add(bd.getInt16(i, Endian.little));
    }
    if (_busy) return;
    _busy = true;
    try {
      while (_porcupine != null && _pending.length >= frameLen) {
        final frame = Int16List.fromList(_pending.sublist(0, frameLen));
        _pending.removeRange(0, frameLen);
        final idx = await _porcupine!.process(frame);
        if (idx >= 0) {
          setState(() => _detections++);
        }
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    _sub = null;
    await _mic.stop();
    await _porcupine?.delete();
    _porcupine = null;
    _pending.clear();
    setState(() => _status = 'stopped');
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Porcupine "Henry" spike')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Text('status: $_status'),
          const SizedBox(height: 12),
          Text('detections: $_detections',
              style: const TextStyle(fontSize: 32)),
          const SizedBox(height: 24),
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: _start, child: const Text('Start listening')),
            OutlinedButton(onPressed: _stop, child: const Text('Stop')),
            OutlinedButton(
                onPressed: () => setState(() => _detections = 0),
                child: const Text('Reset count')),
          ]),
          const SizedBox(height: 24),
          const Text(
            'AEC procedure: (1) leave this listening; (2) from the main screen, '
            'play a Henry monologue through the speaker; (3) watch if detections '
            'increment or the server shows partials while ONLY Henry speaks.',
            style: TextStyle(fontSize: 12),
          ),
        ]),
      ),
    );
  }
}
