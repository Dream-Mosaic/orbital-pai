// On-device wake-word spotting via sherpa-onnx's streaming zipformer KWS.
//
// Open-vocabulary keyword spotting: "Henry" is a BPE-tokenized entry in
// `assets/kws/keywords.txt` matched against a generic 3.3M-parameter model
// (`assets/kws/{encoder,decoder,joiner}.onnx` + `tokens.txt`), so there is
// nothing to train and nothing to expire — unlike the Porcupine spike
// (`lib/spike/porcupine_spike_screen.dart`), which needed a per-keyword
// model trained in the Picovoice Console.
//
// The decode runs in a long-lived worker isolate, not on the isolate that
// owns the mic stream (issue #22). Desktop capture buffers are large enough
// that the Int16→Float32 loop plus ONNX inference, run inline per chunk,
// landed on the raster thread. The cost of moving it is that detection is
// asynchronous: [WakeSpotter.offer] returns nothing and a hit arrives later
// on [WakeSpotter.detections]. That is safe because `WakeGate` buffers every
// chunk it refuses into a 1.5s pre-roll ring and flushes the whole ring on
// the first offer after a detection, so a hit that lands a chunk or two late
// still sends the wake word itself.
//
// Fails open: a model that cannot load (missing/corrupt asset, unsupported
// ABI, ...) or a worker that dies leaves `available == false` and `offer()`
// a no-op. The caller treats that as "no local spotting" and streams audio
// to the cloud continuously rather than going permanently deaf.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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
/// reports each keyword hit on [detections], asynchronously.
abstract interface class WakeSpotter {
  Future<void> start();

  /// Feed 16 kHz mono PCM16. Returns immediately; a keyword hit in this (or
  /// an earlier) chunk is reported later on [detections]. A no-op while
  /// stopped, unavailable or disposed.
  void offer(Uint8List pcm16);

  /// One event per keyword hit. Never carries a hit from before the most
  /// recent [stop] or after [dispose] — a hit decoded from an older mic
  /// session's audio is dropped rather than delivered into a newer one.
  Stream<void> get detections;

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

  /// False when the model failed to load, the worker died, or after
  /// [dispose] — callers must fail open.
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

/// Copies each `assets/kws/*` bundle asset (read through [load]) to a real
/// file in [dir], skipping any whose on-disk copy already has the bundle
/// asset's byte length. Native FFI (sherpa-onnx's ONNX runtime) needs
/// filesystem paths, not Flutter asset-bundle handles.
///
/// Rewriting ~5MB on every process start bought nothing, since the bundled
/// files only change with an app update. Byte length is the "changed" test
/// because every model swap so far has changed it and it costs one `stat`;
/// a same-length replacement would be missed, which is acceptable for
/// assets that ship with the binary. Each copy goes to `name.tmp` and is
/// then renamed over `name`, so a crash mid-write leaves at worst a stray
/// `.tmp` for the next start to overwrite — never a torn `name`, which is
/// the one file the size check trusts.
@visibleForTesting
Future<KwsAssetPaths> copyKwsAssets({
  required Directory dir,
  required Future<ByteData> Function(String key) load,
}) async {
  await dir.create(recursive: true);

  Future<String> copy(String name) async {
    final data = await load('assets/kws/$name');
    final f = File('${dir.path}/$name');
    if (await f.exists() && await f.length() == data.lengthInBytes) {
      return f.path;
    }
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    await tmp.rename(f.path);
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

/// The app-support directory rather than temp: temp may be purged by the OS
/// at any time, which would merely cost a re-copy, but app-support is where
/// data the app regenerates yet would rather keep belongs.
Future<KwsAssetPaths> _defaultLoader() async {
  final support = await getApplicationSupportDirectory();
  return copyKwsAssets(
    dir: Directory('${support.path}/kws'),
    load: rootBundle.load,
  );
}

/// The decoder as the worker isolate sees it. Built, used and freed entirely
/// inside the worker: sherpa-onnx's FFI objects are native pointers bound to
/// the isolate that initialised the bindings and cannot be sent across.
/// Exists as a seam so the isolate plumbing is testable with a fake engine,
/// since the real native library does not load in `flutter test`.
abstract interface class KwsEngine {
  /// Feed one PCM16 chunk; true on the chunk where the keyword fires. The
  /// engine resets its own decoder on a hit so one utterance fires once.
  bool accept(Uint8List pcm16);

  /// Drop in-flight decode state.
  void reset();

  /// Release native resources. Called once, as the worker shuts down.
  void free();
}

/// Builds the engine inside the worker. Must be a top-level or static
/// function (or a closure capturing only sendable values), because it is
/// sent to the worker isolate at spawn.
typedef KwsEngineFactory = KwsEngine Function(KwsAssetPaths paths);

KwsEngine _sherpaEngineFactory(KwsAssetPaths paths) => _SherpaEngine(paths);

class _SherpaEngine implements KwsEngine {
  factory _SherpaEngine(KwsAssetPaths paths) {
    // Per isolate: the bindings are isolate-local globals, so the call made
    // anywhere else in the app does not cover this worker.
    sherpa_onnx.initBindings();
    final spotter = sherpa_onnx.KeywordSpotter(sherpa_onnx.KeywordSpotterConfig(
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
    ));
    return _SherpaEngine._(spotter, spotter.createStream());
  }

  _SherpaEngine._(this._spotter, this._stream);

  final sherpa_onnx.KeywordSpotter _spotter;
  final sherpa_onnx.OnlineStream _stream;

  @override
  bool accept(Uint8List pcm16) {
    _stream.acceptWaveform(samples: pcm16ToFloat32(pcm16), sampleRate: 16000);
    while (_spotter.isReady(_stream)) {
      _spotter.decode(_stream);
    }
    if (_spotter.getResult(_stream).keyword.isEmpty) return false;
    _spotter.reset(_stream);
    return true;
  }

  @override
  void reset() => _spotter.reset(_stream);

  @override
  void free() {
    _stream.free();
    _spotter.free();
  }
}

// Worker protocol. Main → worker: `(generation, TransferableTypedData)` for
// audio, then the bare strings below. Worker → main: `(tag, value)` records.
const String _msgReset = 'reset';
const String _msgClose = 'close';
const String _tagReady = 'ready';
const String _tagFailed = 'failed';
const String _tagWake = 'wake';
const String _tagLog = 'log';

void _workerMain((SendPort, KwsAssetPaths, KwsEngineFactory) args) {
  final (reply, paths, factory) = args;
  final KwsEngine engine;
  try {
    engine = factory(paths);
  } catch (e, st) {
    // Returning with no open port lets the isolate exit on its own; the
    // main side sees `failed` and then the exit notice.
    reply.send((_tagFailed, '$e\n$st'));
    return;
  }
  final inbox = ReceivePort();
  reply.send((_tagReady, inbox.sendPort));
  inbox.listen((Object? msg) {
    switch (msg) {
      case (int gen, TransferableTypedData data):
        try {
          if (engine.accept(data.materialize().asUint8List())) {
            // Echo the generation the chunk was sent under, so main can
            // tell a hit from a session it has since stopped.
            reply.send((_tagWake, gen));
          }
        } catch (e) {
          // Fail open per chunk: one bad decode must not take the whole
          // conversation deaf.
          reply.send((_tagLog, 'decode failed: $e'));
        }
      case _msgReset:
        try {
          engine.reset();
        } catch (e) {
          reply.send((_tagLog, 'reset failed: $e'));
        }
      case _msgClose:
        try {
          engine.free();
        } catch (e) {
          reply.send((_tagLog, 'free failed: $e'));
        }
        // Closing the only open port lets the isolate exit.
        inbox.close();
    }
  });
}

/// One spawned worker. Messages from a worker that is no longer
/// [SherpaWakeSpotter._worker] (it crashed and was replaced, or the spotter
/// was disposed) are recognised by identity and ignored.
class _Worker {
  _Worker(this.inbox);
  final ReceivePort inbox;
  SendPort? port;
}

/// sherpa-onnx-backed [WakeSpotter] for the "Henry" wake word.
///
/// **`start()`/`stop()` are cheap after the first successful load, by
/// design.** The caller (`VoiceController.startMic`/`_release`) calls
/// `start()` on every mic acquire and `stop()` on every mic teardown,
/// including every auto-restart backoff attempt (400ms/2s/8s) — so if this
/// class re-copied its asset files and respawned the worker on each call,
/// every restart would reopen the mic ungated for as long as a full model
/// load takes. Instead:
///  - the extracted asset PATHS are cached for the lifetime of this instance;
///  - the WORKER, and the engine living inside it, stay up across
///    `stop()`/`start()` cycles — `stop()` only resets the decoder's
///    in-flight state, so a keyword partway through decoding when the mic
///    stops does not fire the instant the next session's first frame arrives.
///
/// **Generations.** Detection is asynchronous, so a hit can arrive after the
/// session whose audio produced it has ended. Every chunk is sent tagged
/// with the current generation, the worker echoes it back on a hit, and
/// [stop] bumps it — a hit tagged with anything but the current generation
/// is dropped, as is any hit while stopped.
class SherpaWakeSpotter implements WakeSpotter {
  SherpaWakeSpotter({
    Future<KwsAssetPaths> Function()? loader,
    @visibleForTesting KwsEngineFactory? engineFactory,
  })  : _loader = loader ?? _defaultLoader,
        _engineFactory = engineFactory ?? _sherpaEngineFactory;

  final Future<KwsAssetPaths> Function() _loader;
  final KwsEngineFactory _engineFactory;

  /// Cached once `_loader()` succeeds; reused by every later `start()`.
  KwsAssetPaths? _paths;

  _Worker? _worker;
  bool _available = false;

  /// Shared by concurrent [start] calls, so two sessions racing the first
  /// load (one superseding the other) spawn ONE worker rather than leaking
  /// a second. Cleared when the load settles, so a failed load is retried.
  Future<void>? _loading;

  int _generation = 0;
  bool _running = false;

  final StreamController<void> _detections = StreamController<void>.broadcast();

  /// Set once, by [dispose]. A disposed spotter must never be resurrected —
  /// a [start] whose load was in flight when [dispose] ran re-checks this
  /// after every await, and shuts down anything it built in the meantime
  /// rather than handing it to an instance nothing will ever dispose again.
  bool _disposed = false;

  @override
  bool get available => _available;

  @override
  Stream<void> get detections => _detections.stream;

  @override
  Future<void> start() {
    // A disposed spotter is done for good — see [dispose].
    if (_disposed) return Future<void>.value();
    _running = true;
    // Already loaded: reuse the live worker rather than respawning it. This
    // is what makes a restart cheap, and what makes `start()` safe to call
    // twice in a row with no intervening `stop()`.
    if (_available) return Future<void>.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    ReceivePort? inbox;
    try {
      final paths = _paths ??= await _loader();
      // A dispose() racing this await must not spawn a worker for a disposed
      // instance. Nothing has been allocated yet, so bailing is a no-op.
      if (_disposed) return;

      inbox = ReceivePort('wake-spotter');
      final w = _Worker(inbox);
      final ready = Completer<SendPort?>();
      inbox.listen((Object? msg) => _onWorkerMessage(w, ready, msg));
      await Isolate.spawn(
        _workerMain,
        (inbox.sendPort, paths, _engineFactory),
        onExit: inbox.sendPort,
        onError: inbox.sendPort,
        debugName: 'wake-spotter',
      );
      final port = await ready.future;
      if (port == null) return;
      // Disposed while the engine was being built: it now exists inside the
      // worker, and only the worker can free it — ask it to, then walk away.
      if (_disposed) {
        port.send(_msgClose);
        return;
      }
      w.port = port;
      _worker = w;
      _available = true;
    } catch (e, st) {
      inbox?.close();
      debugPrint('SherpaWakeSpotter: failed to load model, failing open: $e\n$st');
      _available = false;
    }
  }

  void _onWorkerMessage(_Worker w, Completer<SendPort?> ready, Object? msg) {
    switch (msg) {
      case (_tagReady, SendPort port):
        ready.complete(port);
      case (_tagFailed, String error):
        debugPrint('SherpaWakeSpotter: failed to load model, failing open: $error');
        ready.complete(null);
      case (_tagWake, int gen):
        if (_disposed || !_running || gen != _generation) return;
        if (!identical(_worker, w)) return;
        _detections.add(null);
      case (_tagLog, String text):
        debugPrint('SherpaWakeSpotter: $text');
      case [final error, final stack]:
        // An uncaught error; the isolate exits right after (errors are fatal
        // by default), which the exit case below handles.
        debugPrint('SherpaWakeSpotter: worker crashed: $error\n$stack');
      case null:
        // The exit notice. A worker that dies before `ready` must not park
        // `start()` forever; one that dies after takes spotting with it, so
        // fail open — the next start() respawns it.
        if (!ready.isCompleted) ready.complete(null);
        w.inbox.close();
        if (identical(_worker, w)) {
          _worker = null;
          _available = false;
          debugPrint('SherpaWakeSpotter: worker exited, failing open');
        }
    }
  }

  @override
  void offer(Uint8List pcm16) {
    if (_disposed || !_available || !_running) return;
    final port = _worker?.port;
    if (port == null) return;
    // One copy into a transferable buffer; the worker materialises it
    // without a second. The caller keeps its own chunk for the gate.
    port.send((_generation, TransferableTypedData.fromList([pcm16])));
  }

  @override
  Future<void> stop() async {
    // Deliberately does NOT shut the worker down — see the class doc. Bumps
    // the generation synchronously, before any await, so a hit already in
    // flight from this session is dropped even if it lands before the
    // caller's next line runs. The reset rides the same port as the audio,
    // so the worker applies it after every chunk this session sent.
    if (_disposed) return;
    _running = false;
    _generation++;
    _worker?.port?.send(_msgReset);
  }

  @override
  Future<void> dispose() async {
    // Idempotent: VoiceController.dispose() is the only intended caller and
    // calls this once, but a double-call (a defensive future caller, a test)
    // must not double-free.
    if (_disposed) return;
    _disposed = true;
    _available = false;
    _running = false;
    final w = _worker;
    _worker = null;
    // The worker frees the engine and exits; its exit notice closes the
    // inbox. A load still in flight handles its own worker (see [_load]).
    w?.port?.send(_msgClose);
    unawaited(_detections.close());
  }
}
