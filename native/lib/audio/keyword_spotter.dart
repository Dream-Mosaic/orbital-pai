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

  Future<void> stop();

  /// False when the model failed to load — callers must fail open.
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
class SherpaWakeSpotter implements WakeSpotter {
  SherpaWakeSpotter({Future<KwsAssetPaths> Function()? loader})
      : _loader = loader ?? _defaultLoader;

  final Future<KwsAssetPaths> Function() _loader;

  sherpa_onnx.KeywordSpotter? _spotter;
  sherpa_onnx.OnlineStream? _stream;
  bool _available = false;

  @override
  bool get available => _available;

  @override
  Future<void> start() async {
    try {
      final paths = await _loader();
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
    if (!_available) return false;
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
    _stream?.free();
    _stream = null;
    _spotter?.free();
    _spotter = null;
  }
}
