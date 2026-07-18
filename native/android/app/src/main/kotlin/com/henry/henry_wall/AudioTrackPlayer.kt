package com.henry.henry_wall

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/// Spike-grade gapless PCM16 mono player. MODE_STREAM AudioTrack fed by a
/// background writer thread. playedMs() is derived from the playback head
/// position relative to the current run's start (reset on stopAndFlush()).
///
/// Note: AudioTrack.playbackHeadPosition wraps at 2^31 frames (~24.8 h at
/// 24 kHz) — fine for a spike; documented here rather than guarded.
class AudioTrackPlayer(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "henry/audio_track")
    private var track: AudioTrack? = null
    private var sampleRate = 24000
    private val queue = LinkedBlockingQueue<ByteArray>()
    private var writer: Thread? = null
    private val running = AtomicBoolean(false)

    @Volatile private var idle = true
    @Volatile private var runStartFrames = 0

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> { init(call.argument<Int>("sampleRate") ?: 24000); result.success(null) }
            "write" -> { enqueue(call.arguments as ByteArray); result.success(null) }
            "stopAndFlush" -> result.success(stopAndFlush())
            "playedMs" -> result.success(playedMs())
            "setVolume" -> {
                track?.setVolume((call.argument<Double>("volume") ?: 1.0).toFloat())
                result.success(null)
            }
            "dispose" -> { dispose(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun init(rate: Int) {
        dispose()
        sampleRate = rate
        val minBuf = AudioTrack.getMinBufferSize(
            rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val bufSize = maxOf(minBuf, rate * 2) // ~0.5 s cushion
        track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build())
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(rate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build())
            .setBufferSizeInBytes(bufSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        track!!.play()
        idle = true
        runStartFrames = 0
        running.set(true)
        writer = Thread { writerLoop() }.also { it.start() }
    }

    private fun writerLoop() {
        while (running.get()) {
            val chunk = queue.poll(100, TimeUnit.MILLISECONDS) ?: continue
            val t = track ?: continue
            if (idle) { runStartFrames = t.playbackHeadPosition; idle = false }
            var off = 0
            while (off < chunk.size && running.get()) {
                val n = t.write(chunk, off, chunk.size - off, AudioTrack.WRITE_BLOCKING)
                if (n < 0) break
                off += n
            }
        }
    }

    private fun enqueue(bytes: ByteArray) { queue.offer(bytes) }

    private fun playedMs(): Int {
        val t = track ?: return 0
        if (idle) return 0
        val frames = (t.playbackHeadPosition - runStartFrames).toLong()
        return (frames * 1000L / sampleRate).toInt()
    }

    private fun stopAndFlush(): Int {
        val t = track ?: return 0
        val played = playedMs()
        queue.clear()
        t.pause()
        t.flush()
        t.play()   // ready for the next run
        idle = true
        return played
    }

    private fun dispose() {
        running.set(false)
        writer?.join(200)
        writer = null
        queue.clear()
        track?.let { it.pause(); it.flush(); it.release() }
        track = null
        idle = true
    }
}
