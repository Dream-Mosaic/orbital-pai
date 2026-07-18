import 'dart:typed_data';
import 'package:record/record.dart';

/// 16 kHz mono PCM16LE mic stream, matching the server's stt_sample_rate.
/// Requests platform echo-cancel / noise-suppress / auto-gain and the
/// voice-communication audio source (which itself engages the platform AEC).
class MicCapture {
  final AudioRecorder _recorder = AudioRecorder();
  bool _recording = false;

  bool get isRecording => _recording;

  Future<Stream<Uint8List>> start() async {
    if (!await _recorder.hasPermission()) {
      throw StateError('microphone permission denied');
    }
    const config = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
      autoGain: true,
      androidConfig: AndroidRecordConfig(
        audioSource: AndroidAudioSource.voiceCommunication,
      ),
    );
    final stream = await _recorder.startStream(config);
    _recording = true;
    return stream;
  }

  Future<void> stop() async {
    if (!_recording) return;
    await _recorder.stop();
    _recording = false;
  }
}
