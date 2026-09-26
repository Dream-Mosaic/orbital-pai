import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/audio/keyword_spotter.dart';

const _paths = KwsAssetPaths(
    encoder: '', decoder: '', joiner: '', tokens: '', keywords: '');

/// Stands in for sherpa inside the worker isolate: "hears the keyword" once
/// it has accumulated 640 bytes since the last hit or reset, so a test can
/// tell whether a [WakeSpotter.stop] actually reset the decoder. A chunk
/// starting with 0xEE kills the worker, modelling a native crash.
class _ByteCountEngine implements KwsEngine {
  int _bytes = 0;

  @override
  bool accept(Uint8List pcm16) {
    if (pcm16.isNotEmpty && pcm16[0] == 0xEE) Isolate.exit();
    _bytes += pcm16.length;
    if (_bytes < 640) return false;
    _bytes = 0;
    return true;
  }

  @override
  void reset() => _bytes = 0;

  @override
  void free() {}
}

KwsEngine _byteCountFactory(KwsAssetPaths _) => _ByteCountEngine();

KwsEngine _throwingFactory(KwsAssetPaths _) => throw StateError('bad model');

SherpaWakeSpotter _fakeEngineSpotter() => SherpaWakeSpotter(
    loader: () async => _paths, engineFactory: _byteCountFactory);

/// Waits for the next detection, failing fast rather than hanging the suite.
Future<void> _nextHit(WakeSpotter s) =>
    s.detections.first.timeout(const Duration(seconds: 5));

/// For the negative cases: "no hit" can only be shown by waiting a while.
/// Generous next to a same-process isolate round trip, which is sub-ms.
Future<void> _quietPeriod() => Future<void>.delayed(const Duration(milliseconds: 200));

void main() {
  group('pcm16ToFloat32', () {
    test('converts int16 PCM to normalized float32', () {
      // -32768, 0, 32767 little-endian
      final pcm = Uint8List.fromList([0x00, 0x80, 0x00, 0x00, 0xFF, 0x7F]);
      final out = pcm16ToFloat32(pcm);
      expect(out.length, 3);
      expect(out[0], closeTo(-1.0, 1e-6));
      expect(out[1], 0.0);
      expect(out[2], closeTo(1.0, 1e-4));
    });

    test('an odd trailing byte is dropped, not misread', () {
      final out = pcm16ToFloat32(Uint8List.fromList([0x00, 0x00, 0x11]));
      expect(out.length, 1);
    });
  });

  group('SherpaWakeSpotter fail-open', () {
    test('available is false and offer is a no-op when the model failed '
        'to load', () async {
      final s = SherpaWakeSpotter(loader: () async => throw StateError('no asset'));
      await s.start();
      expect(s.available, isFalse);
      s.offer(Uint8List(320)); // must fail open, never throw
    });

    test('an engine that fails to build inside the worker fails open', () async {
      final s = SherpaWakeSpotter(
          loader: () async => _paths, engineFactory: _throwingFactory);
      addTearDown(s.dispose);
      await s.start();
      expect(s.available, isFalse);
    });

    test('the real sherpa engine, unloadable in flutter test, fails open '
        'from inside the worker rather than throwing', () async {
      // No native library matches a plain `flutter test` process, so
      // `initBindings()` throws in the worker — the same shape as an
      // unsupported ABI on a device.
      final s = SherpaWakeSpotter(loader: () async => _paths);
      addTearDown(s.dispose);
      await s.start();
      expect(s.available, isFalse);
    });

    test('a failed load can be retried — the "already loaded" short-circuit '
        'only applies once available', () async {
      // start() short-circuits when `available` is already true, so a mic
      // restart reuses the warm worker instead of respawning it. That guard
      // must not also latch a FAILED load: a spotter that never became
      // available has nothing to reuse, and every later startMic() must
      // keep trying.
      var calls = 0;
      final s = SherpaWakeSpotter(loader: () async {
        calls++;
        throw StateError('no asset');
      });
      await s.start();
      expect(s.available, isFalse);
      await s.start();
      expect(calls, 2,
          reason: 'a failed load must not be permanently latched by the reuse guard');
    });

    test('stop() before any successful start() is a safe no-op', () async {
      final s = SherpaWakeSpotter(loader: () async => throw StateError('no asset'));
      await s.stop();
      expect(s.available, isFalse);
    });

    test('a worker that dies mid-session fails open, and the next start() '
        'respawns it', () async {
      final s = _fakeEngineSpotter();
      addTearDown(s.dispose);
      await s.start();
      expect(s.available, isTrue);

      s.offer(Uint8List(320)..[0] = 0xEE);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (s.available && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(s.available, isFalse, reason: 'a dead worker must not keep the gate shut');
      s.offer(Uint8List(320)); // no worker: a no-op, not a throw

      await s.start();
      expect(s.available, isTrue);
      final hit = _nextHit(s);
      s.offer(Uint8List(640));
      await hit;
    });

    test('a dispose() racing an in-flight start() does not resurrect the '
        'engine once the loader resolves', () async {
      // VoiceController.dispose() fires `_spotter.dispose()` unawaited while
      // startMic()'s `await _spotter.start()` may still be mid-load (a
      // sign-out during model load). start() must not spawn a worker, or
      // flip `available`, on an instance that is already disposed by the
      // time its own await returns.
      //
      // Uses the REAL engine factory and captures debugPrint rather than
      // trusting `available` alone: on this host the worker's
      // `initBindings()` throws and reports back, which would ALSO leave
      // `available` false with the guard reverted. No debug output at all is
      // proof no worker was ever spawned — on a device, where the engine
      // would have loaded, that is the difference between leaking it and
      // not.
      final messages = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) messages.add(message);
      };
      addTearDown(() => debugPrint = originalDebugPrint);

      final loaderGate = Completer<KwsAssetPaths>();
      final s = SherpaWakeSpotter(loader: () => loaderGate.future);

      final starting = s.start();
      await s.dispose();
      loaderGate.complete(_paths);
      await starting;
      await _quietPeriod();

      expect(s.available, isFalse);
      s.offer(Uint8List(320));
      expect(messages, isEmpty,
          reason: 'a disposed instance must bail out before spawning a worker');
    });

    test('a dispose() landing while the worker builds its engine still '
        'leaves the spotter inert', () async {
      final s = _fakeEngineSpotter();
      final starting = s.start();
      // The loader has resolved and the spawn is in flight by the next
      // event-loop turn; dispose lands before the worker reports ready.
      await Future<void>.delayed(Duration.zero);
      await s.dispose();
      await starting;
      expect(s.available, isFalse);
    });
  });

  group('SherpaWakeSpotter worker isolate', () {
    test('a hit decoded in the worker is delivered on detections', () async {
      final s = _fakeEngineSpotter();
      addTearDown(s.dispose);
      await s.start();
      expect(s.available, isTrue);

      final hit = _nextHit(s);
      s.offer(Uint8List(320));
      s.offer(Uint8List(320));
      await hit;
    });

    test('concurrent start() calls share one load instead of spawning two '
        'workers', () async {
      var loads = 0;
      final s = SherpaWakeSpotter(
          loader: () async {
            loads++;
            return _paths;
          },
          engineFactory: _byteCountFactory);
      addTearDown(s.dispose);
      await Future.wait([s.start(), s.start()]);
      expect(s.available, isTrue);
      expect(loads, 1);
    });

    test('a hit still in flight when stop() runs is dropped, not delivered '
        'into the next session', () async {
      final s = _fakeEngineSpotter();
      addTearDown(s.dispose);
      await s.start();

      var hits = 0;
      final sub = s.detections.listen((_) => hits++);
      addTearDown(sub.cancel);

      // Enough to fire, then stop before the worker can answer: its reply
      // carries the old generation.
      s.offer(Uint8List(640));
      await s.stop();
      await s.start();

      final hit = _nextHit(s);
      s.offer(Uint8List(640));
      await hit;
      // Waited out rather than stopping at the first hit: with the guard
      // gone, `hit` would complete on the STALE event, and only the count
      // afterwards tells the two apart.
      await _quietPeriod();
      expect(hits, 1, reason: 'only the new session\'s hit may be delivered');
    });

    test('stop() resets the decoder, so half a keyword does not carry into '
        'the next session', () async {
      final s = _fakeEngineSpotter();
      addTearDown(s.dispose);
      await s.start();

      var hits = 0;
      final sub = s.detections.listen((_) => hits++);
      addTearDown(sub.cancel);

      s.offer(Uint8List(320));
      await s.stop();
      await s.start();
      s.offer(Uint8List(320));
      await _quietPeriod();
      expect(hits, 0, reason: 'without the reset these two halves would fire');

      final hit = _nextHit(s);
      s.offer(Uint8List(320));
      await hit;
    });

    test('offer() while stopped is ignored', () async {
      final s = _fakeEngineSpotter();
      addTearDown(s.dispose);
      await s.start();
      await s.stop();

      var hits = 0;
      final sub = s.detections.listen((_) => hits++);
      addTearDown(sub.cancel);
      s.offer(Uint8List(640));
      await _quietPeriod();
      expect(hits, 0);
    });

    test('a hit in flight when dispose() runs is never delivered, and '
        'dispose is final and idempotent', () async {
      final s = _fakeEngineSpotter();
      await s.start();

      final hits = s.detections.toList();
      s.offer(Uint8List(640));
      await s.dispose();
      await s.dispose();
      expect(await hits.timeout(const Duration(seconds: 5)), isEmpty);

      await s.start();
      expect(s.available, isFalse, reason: 'a disposed spotter stays disposed');
    });
  });

  group('copyKwsAssets', () {
    late Directory dir;
    late Map<String, Uint8List> bundle;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('kws_copy_test');
      addTearDown(() => dir.delete(recursive: true));
      bundle = {
        for (final n in [
          'encoder.onnx',
          'decoder.onnx',
          'joiner.onnx',
          'tokens.txt',
          'keywords.txt',
        ])
          'assets/kws/$n': Uint8List.fromList(List.filled(8, n.length)),
      };
    });

    Future<ByteData> load(String key) async {
      return ByteData.sublistView(bundle[key]!);
    }

    test('copies every asset on first run and returns their paths', () async {
      final paths = await copyKwsAssets(dir: dir, load: load);
      expect(paths.encoder, '${dir.path}/encoder.onnx');
      expect(File(paths.keywords).readAsBytesSync(), bundle['assets/kws/keywords.txt']);
      expect(dir.listSync().whereType<File>().where((f) => f.path.endsWith('.tmp')),
          isEmpty, reason: 'each temp file is renamed into place');
    });

    test('an on-disk copy with the same byte length is left alone', () async {
      await copyKwsAssets(dir: dir, load: load);
      // Same length, different bytes: if this survives, the copy was skipped.
      final marker = Uint8List.fromList(List.filled(8, 0xAB));
      File('${dir.path}/encoder.onnx').writeAsBytesSync(marker);

      await copyKwsAssets(dir: dir, load: load);
      expect(File('${dir.path}/encoder.onnx').readAsBytesSync(), marker);
    });

    test('a missing or different-length copy is rewritten', () async {
      await copyKwsAssets(dir: dir, load: load);
      File('${dir.path}/decoder.onnx').deleteSync();
      File('${dir.path}/joiner.onnx').writeAsBytesSync([1, 2, 3]);

      await copyKwsAssets(dir: dir, load: load);
      expect(File('${dir.path}/decoder.onnx').readAsBytesSync(),
          bundle['assets/kws/decoder.onnx']);
      expect(File('${dir.path}/joiner.onnx').readAsBytesSync(),
          bundle['assets/kws/joiner.onnx']);
    });

    test('a stale .tmp from a crashed copy does not count as the asset', () async {
      File('${dir.path}/tokens.txt.tmp')
          .writeAsBytesSync(bundle['assets/kws/tokens.txt']!);
      final paths = await copyKwsAssets(dir: dir, load: load);
      expect(File(paths.tokens).readAsBytesSync(), bundle['assets/kws/tokens.txt']);
      expect(File('${dir.path}/tokens.txt.tmp').existsSync(), isFalse);
    });
  });
}
