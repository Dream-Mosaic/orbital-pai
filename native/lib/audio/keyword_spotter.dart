// On-device wake-word spotting via sherpa-onnx's streaming zipformer KWS.
//
// Open-vocabulary keyword spotting: "Henry" is a BPE-tokenized entry in
// `assets/kws/keywords.txt` matched against a generic 3.3M-parameter model
// (`assets/kws/{encoder,decoder,joiner}.onnx` + `tokens.txt`), so there is
// nothing to train and nothing to expire — unlike the Porcupine spike
// (`lib/spike/porcupine_spike_screen.dart`), which needed a per-keyword
// model trained in the Picovoice Console.
//
// Fails open: a model that cannot load (missing/corrupt asset, unsupported
// ABI, ...) leaves `available == false` and `offer()` returns false without
// throwing. The caller (a later task) treats that as "no local spotting" and
// streams audio to the cloud continuously rather than going permanently
// deaf.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

/// int16 little-endian PCM → the normalized float32 sherpa-onnx expects.
/// An odd trailing byte is dropped: half a sample is not a sample.
Float32List pcm16ToFloat32(Uint8List pcm) {
  final n = pcm.length ~/ 2;
  final bd = ByteData.sublistView(pcm);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// On-device wake-word detector. Feed it 16 kHz mono PCM16 frames; it
/// reports true on the frame where the configured keyword fires.
abstract interface class WakeSpotter {
  Future<void> start();

  /// Feed 16 kHz mono PCM16. Returns true on the frame where the keyword
  /// fires.
  bool offer(Uint8List pcm16);

  /// Reset in-flight decode state, cheaply, for reuse on the NEXT [start] —
  /// called on every mic-session teardown (see `VoiceController._release`),
  /// auto-restart backoff included. Deliberately does NOT release the engine
  /// — see [dispose] for that.
  Future<void> stop();

  /// Release the engine for good. Unlike [stop] (cheap, reset-only, called
  /// on every ordinary mic teardown so the engine stays warm across
  /// restarts), this frees the underlying native resources and must be
  /// called exactly once, when THIS SPOTTER ITSELF is going away — i.e. from
  /// `VoiceController.dispose()`, never from a mic-session teardown. A
  /// controller rebuilt after this (e.g. a fresh sign-in) constructs a new
  /// [WakeSpotter], so nothing needs `dispose()` to leave this instance
  /// reusable. Idempotent, and safe even if [start] never succeeded.
  Future<void> dispose();

  /// False when the model failed to load, or after [dispose] — callers must
  /// fail open.
  bool get available;
}

/// Paths to the four assets a [sherpa_onnx.KeywordSpotter] needs on disk.
class KwsAssetPaths {
  const KwsAssetPaths({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
    required this.keywords,
  });

  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;
  final String keywords;
}

/// Copies each `assets/kws/*` bundle asset to a real file in the temp
/// directory. Native FFI (sherpa-onnx's ONNX runtime) needs filesystem
/// paths, not Flutter asset-bundle handles — same pattern as
/// `PorcupineSpikeScreen._copyAssetToFile`.
Future<KwsAssetPaths> _defaultLoader() async {
  final dir = await getTemporaryDirectory();

  Future<String> copy(String name) async {
    final bytes = await rootBundle.load('assets/kws/$name');
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    return f.path;
  }

  return KwsAssetPaths(
    encoder: await copy('encoder.onnx'),
    decoder: await copy('decoder.onnx'),
    joiner: await copy('joiner.onnx'),
    tokens: await copy('tokens.txt'),
    keywords: await copy('keywords.txt'),
  );
}

/// sherpa-onnx-backed [WakeSpotter] for the "Henry" wake word.
///
/// **`start()`/`stop()` are cheap after the first successful load, by
/// design.** The caller (`VoiceController.startMic`/`_release`) calls
/// `start()` on every mic acquire and `stop()` on every mic teardown,
/// including every auto-restart backoff attempt (400ms/2s/8s) — so if this
/// class re-copied its four asset files and rebuilt the ONNX engine on each
/// call, every restart would reopen the mic with no subscriber for as long
/// as a full model load takes. Instead:
///  - the extracted asset PATHS are cached for the lifetime of this instance
///    (the bundled files never change, so re-copying them bought nothing);
///  - the ENGINE (`KeywordSpotter` + its `OnlineStream`) is built once and
///    kept warm across `stop()`/`start()` cycles rather than freed and
///    rebuilt — `stop()` only resets the decoder's in-flight state, so a
///    keyword partway through decoding when the mic stops does not fire the
///    instant the next session's first frame arrives.
class SherpaWakeSpotter implements WakeSpotter {
  SherpaWakeSpotter({Future<KwsAssetPaths> Function()? loader})
      : _loader = loader ?? _defaultLoader;

  final Future<KwsAssetPaths> Function() _loader;

  /// Cached once `_loader()` succeeds; reused by every later `start()`.
  KwsAssetPaths? _paths;

  sherpa_onnx.KeywordSpotter? _spotter;
  sherpa_onnx.OnlineStream? _stream;
  bool _available = false;

  /// Set once, by [dispose]. A disposed spotter must never be resurrected —
  /// [start] would otherwise rebuild an engine (fine) but callers that raced
  /// [dispose] against an in-flight [start]/[offer] could still touch a
  /// pointer freed out from under them; latching this is what makes that
  /// impossible rather than merely unlikely.
  bool _disposed = false;

  @override
  bool get available => _available;

  @override
  Future<void> start() async {
    // A disposed spotter is done for good — see [dispose]. Restarting it
    // would mean allocating a new engine on an instance nothing holds a
    // reason to keep alive, and — the actual hazard — racing whatever freed
    // `_spotter`/`_stream` out from under a start already in flight.
    if (_disposed) return;
    // Already loaded: reuse the live engine rather than tearing it down and
    // rebuilding it. This is what makes a restart cheap, and it is also what
    // makes `start()` safe to call twice in a row with no intervening
    // `stop()` — a real path (a session superseded, or `stream.listen`
    // throwing, right after this call) that used to leak a whole
    // KeywordSpotter/OnlineStream pair per occurrence, since the second call
    // would simply overwrite `_spotter`/`_stream` without freeing the first.
    if (_available) return;
    try {
      final paths = _paths ??= await _loader();
      sherpa_onnx.initBindings();

      final config = sherpa_onnx.KeywordSpotterConfig(
        model: sherpa_onnx.OnlineModelConfig(
          transducer: sherpa_onnx.OnlineTransducerModelConfig(
            encoder: paths.encoder,
            decoder: paths.decoder,
            joiner: paths.joiner,
          ),
          tokens: paths.tokens,
          numThreads: 1,
          provider: 'cpu',
          debug: false,
        ),
        keywordsFile: paths.keywords,
        keywordsThreshold: 0.25,
        keywordsScore: 1.0,
      );

      final spotter = sherpa_onnx.KeywordSpotter(config);
      _stream = spotter.createStream();
      _spotter = spotter;
      _available = true;
    } catch (e, st) {
      debugPrint('SherpaWakeSpotter: failed to load model, failing open: $e\n$st');
      _available = false;
      _spotter = null;
      _stream = null;
    }
  }

  @override
  bool offer(Uint8List pcm16) {
    if (_disposed || !_available) return false;
    final spotter = _spotter;
    final stream = _stream;
    if (spotter == null || stream == null) return false;

    try {
      stream.acceptWaveform(samples: pcm16ToFloat32(pcm16), sampleRate: 16000);
      while (spotter.isReady(stream)) {
        spotter.decode(stream);
      }
      final result = spotter.getResult(stream);
      if (result.keyword.isNotEmpty) {
        spotter.reset(stream);
        return true;
      }
      return false;
    } catch (e) {
      // Fail open mid-stream too: a decode-time crash must not take the
      // whole conversation deaf.
      debugPrint('SherpaWakeSpotter: offer() failed, failing open: $e');
      return false;
    }
  }

  @override
  Future<void> stop() async {
    // Deliberately does NOT free the engine — see the class doc. Resets the
    // decoder state only, so the next `start()` (a no-op once loaded) begins
    // clean rather than mid-keyword. Guarded because `available` may already
    // be false here (a `stop()` reached before any successful `start()`, or
    // after a load failure) with nothing live to reset, and because a
    // disposed spotter has nothing left to reset either.
    if (_disposed) return;
    final spotter = _spotter;
    final stream = _stream;
    if (spotter == null || stream == null) return;
    try {
      spotter.reset(stream);
    } catch (e) {
      // Same fail-open posture as offer(): a reset failure must not be
      // allowed to propagate into a mic-teardown path that has to be
      // non-throwing end to end.
      debugPrint('SherpaWakeSpotter: reset on stop() failed: $e');
    }
  }

  @override
  Future<void> dispose() async {
    // Idempotent: VoiceController.dispose() is the only intended caller and
    // calls this once, but a double-call (a defensive future caller, a test)
    // must not double-free.
    if (_disposed) return;
    _disposed = true;
    _available = false;
    _stream?.free();
    _stream = null;
    _spotter?.free();
    _spotter = null;
  }
}
