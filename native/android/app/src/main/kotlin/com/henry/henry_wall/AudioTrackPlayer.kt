package com.henry.henry_wall

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioDeviceCallback
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/// Spike-grade gapless PCM16 mono player. MODE_STREAM AudioTrack fed by a
/// background writer thread. playedMs() is derived from the playback head
/// position relative to the current run's start. A run ends on stopAndFlush()
/// (barge-in) or when the queue drains and the head catches up (natural end).
///
/// Note: AudioTrack.playbackHeadPosition wraps at 2^31 frames (~24.8 h at
/// 24 kHz) — fine for a spike; documented here rather than guarded.
class AudioTrackPlayer(messenger: BinaryMessenger, private val context: Context) :
    MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "henry/audio_track")
    private val audio =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    @Volatile private var track: AudioTrack? = null
    private var sampleRate = 24000
    private val queue = LinkedBlockingQueue<ByteArray>()
    private var writer: Thread? = null
    private val running = AtomicBoolean(false)

    @Volatile private var idle = true
    // Playback head position when the current run started (absolute frames).
    @Volatile private var runStartFrames = 0
    // Frames written for the current run (run-relative), so the writer can tell
    // when the head has caught up == the run ended naturally.
    @Volatile private var runWrittenFrames = 0
    // Bumped by stopAndFlush()/dispose() so a writer blocked mid-chunk discards
    // the remainder instead of feeding it into the freshly flushed track.
    @Volatile private var generation = 0

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
        // USAGE_VOICE_COMMUNICATION, not USAGE_MEDIA. Android's echo canceller
        // cancels the mic against the VOICE-COMMUNICATION stream only; a media
        // stream is not part of its reference signal. With MEDIA here the mic
        // (already opened on the voiceCommunication source) heard Henry's own
        // answers unsuppressed, Ink-2 endpointed them as a fresh turn, and he
        // answered himself in a loop — see the "heard:" lines echoing his own
        // "brain:" lines in companion.log.
        enterCommunicationMode()
        track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
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
        runWrittenFrames = 0
        running.set(true)
        writer = Thread { writerLoop() }.also { it.start() }
    }

    /// Re-routes whenever something is plugged in or unplugged. setCommunicationDevice
    /// PINS a route, so without this, earbuds connected mid-answer would be ignored
    /// for the rest of the session.
    private val routeWatcher = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>?) = route()
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>?) = route()
    }
    private var watching = false

    /// Put the whole audio session into communication mode, which is what arms the
    /// platform AEC/NS against our own playback, then choose a route.
    private fun enterCommunicationMode() {
        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        route()
        if (!watching) {
            audio.registerAudioDeviceCallback(routeWatcher, Handler(Looper.getMainLooper()))
            watching = true
        }
    }

    /// Headset if there is one, loudspeaker otherwise.
    ///
    /// Communication mode defaults to the EARPIECE, which on a hands-free device
    /// means Henry is inaudible — so the speaker is only a FALLBACK, not a forced
    /// route. Anything that is neither the earpiece nor the built-in speaker is a
    /// headset of some kind (wired, USB, BT SCO, BLE, hearing aid); testing by
    /// exclusion means a route type we have never heard of still wins over the
    /// speaker, which is the behaviour you want when you have earbuds in.
    private fun route() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val devices = audio.availableCommunicationDevices
            val headset = devices.firstOrNull {
                it.type != AudioDeviceInfo.TYPE_BUILTIN_EARPIECE &&
                    it.type != AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
            }
            val target = headset
                ?: devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            target?.let { audio.setCommunicationDevice(it) }
        } else {
            @Suppress("DEPRECATION")
            val wired = audio.isWiredHeadsetOn
            @Suppress("DEPRECATION")
            val bt = audio.isBluetoothScoOn || audio.isBluetoothA2dpOn
            @Suppress("DEPRECATION")
            audio.isSpeakerphoneOn = !(wired || bt)
        }
    }

    /// Hand the audio focus/mode back so the device is not left stuck in call
    /// mode (media volume, earpiece routing) after Henry is torn down.
    private fun leaveCommunicationMode() {
        if (watching) {
            audio.unregisterAudioDeviceCallback(routeWatcher)
            watching = false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audio.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            audio.isSpeakerphoneOn = false
        }
        audio.mode = AudioManager.MODE_NORMAL
    }

    private fun writerLoop() {
        while (running.get()) {
            val chunk = queue.poll(100, TimeUnit.MILLISECONDS)
            if (chunk == null) {
                // Queue drained. Once the playback head has caught up to every
                // frame written for this run, the run ended naturally and the
                // next chunk starts a fresh one — mirrors the "idle gap: a new
                // run starts now" reset in assets/js/voice/playback.js. Without
                // this, runStartFrames stays anchored at the first turn and
                // playedMs() reports every turn since the last stopAndFlush().
                val t = track
                if (!idle && t != null &&
                    (t.playbackHeadPosition - runStartFrames) >= runWrittenFrames) {
                    idle = true
                }
                continue
            }
            // Captured the instant we take the chunk: a stopAndFlush() from here
            // on must invalidate what's left of it.
            val gen = generation
            val t = track ?: continue
            if (idle) {
                runStartFrames = t.playbackHeadPosition
                runWrittenFrames = 0
                idle = false
            }
            var off = 0
            while (off < chunk.size && running.get() && generation == gen) {
                val n = t.write(chunk, off, chunk.size - off, AudioTrack.WRITE_BLOCKING)
                if (n < 0) break
                off += n
                runWrittenFrames += n / 2 // PCM16 mono: 2 bytes per frame
            }
        }
    }

    private fun enqueue(bytes: ByteArray) { queue.offer(bytes) }

    private fun playedMs(): Int {
        val t = track ?: return 0
        if (idle) return 0
        // Clamp to what this run actually wrote (the head can never legitimately
        // pass it; guards a mid-flush read too).
        val frames = (t.playbackHeadPosition - runStartFrames)
            .coerceIn(0, runWrittenFrames).toLong()
        return (frames * 1000L / sampleRate).toInt()
    }

    private fun stopAndFlush(): Int {
        val t = track ?: return 0
        val played = playedMs()
        // Invalidate the in-flight chunk BEFORE pause() unblocks the writer,
        // otherwise it resumes writing the remainder into the flushed track.
        generation++
        idle = true
        queue.clear()
        t.pause()
        t.flush()
        t.play()   // ready for the next run
        return played
    }

    private fun dispose() {
        running.set(false)
        generation++
        // pause() unblocks a writer parked in WRITE_BLOCKING (up to the ~0.5 s
        // buffer cushion) so the join below doesn't time out and release() the
        // track out from under it.
        track?.pause()
        writer?.join(200)
        writer = null
        queue.clear()
        track?.let { it.flush(); it.release() }
        track = null
        // Only surrender call mode once the track is really gone; init() calls
        // dispose() first, and dropping the mode between two live tracks would
        // bounce routing back to the earpiece mid-session.
        leaveCommunicationMode()
        idle = true
        runStartFrames = 0
        runWrittenFrames = 0
    }
}
