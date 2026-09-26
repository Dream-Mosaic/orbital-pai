package com.orbital.pai

import android.content.Context
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
/// position relative to the current run's start. A run ends on stopAndFlush()
/// (barge-in) or when the queue drains and the head catches up (natural end).
///
/// Audio mode, route and focus are NOT this class's business: they belong to
/// [AudioRouteOwner], which the player acquires for as long as it has a track.
///
/// Frame positions are 64-bit ([HeadClock]). AudioTrack.playbackHeadPosition
/// is a 32-bit counter (~24.8 h of played audio at 24 kHz before it goes
/// negative as a signed Int); read raw, a wrap parked the orb at rest for
/// good — the Dart poll's drain test `f >= writtenFrames` went false forever
/// and `levelAt(f)` fell into its before-first branch.
class AudioTrackPlayer(messenger: BinaryMessenger, context: Context) :
    MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "henry/audio_track")
    private val route = AudioRouteOwner(context)
    private val head = HeadClock()
    @Volatile private var track: AudioTrack? = null
    private var sampleRate = 24000
    private val queue = LinkedBlockingQueue<ByteArray>()
    private var writer: Thread? = null
    private val running = AtomicBoolean(false)

    @Volatile private var idle = true
    // Playback head position when the current run started (absolute frames).
    @Volatile private var runStartFrames = 0L
    // Frames written for the current run (run-relative), so the writer can tell
    // when the head has caught up == the run ended naturally.
    @Volatile private var runWrittenFrames = 0L
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
            "playedFrames" -> result.success(playedFrames())
            "setVolume" -> {
                track?.setVolume((call.argument<Double>("volume") ?: 1.0).toFloat())
                result.success(null)
            }
            "dispose" -> { dispose(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun init(rate: Int) {
        // Not dispose(): that releases the route, and dropping call mode
        // between two live tracks bounces routing to the earpiece mid-session.
        releaseTrack()
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
        // "brain:" lines in companion.log. The mode that makes that stream
        // count as the AEC reference is the route owner's (idempotent here).
        route.acquire()
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
        head.reset()
        runStartFrames = 0L
        runWrittenFrames = 0L
        running.set(true)
        writer = Thread { writerLoop() }.also { it.start() }
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
                    (head.read(t) - runStartFrames) >= runWrittenFrames) {
                    idle = true
                }
                continue
            }
            // Captured the instant we take the chunk: a stopAndFlush() from here
            // on must invalidate what's left of it.
            val gen = generation
            val t = track ?: continue
            if (idle) {
                runStartFrames = head.read(t)
                runWrittenFrames = 0L
                idle = false
                // The fallback reassert below API 31, which has no mode-change
                // callback: the start of an answer is the moment a mode lost
                // to a call (or anyone) costs us AEC, so check it here.
                route.requestCheck()
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

    /// Frames played since the last flush (or init) — NOT run-relative.
    ///
    /// Deliberately the head position itself (widened, not re-anchored):
    /// AudioTrack resets it on flush(), and flush() is the same event Dart
    /// resets its own accounting on, so the two stay on one timeline with no
    /// anchoring to keep in step. A Long crosses the channel as a Dart int.
    ///
    /// playedMs() below is run-relative on purpose — barge-in accounting wants
    /// "how much of THIS answer did they hear". The orb wants the opposite: a
    /// clock that never re-anchors, because a clock that re-anchors under a
    /// consumer that doesn't is precisely what made the waveform reset.
    private fun playedFrames(): Long = track?.let { head.read(it) } ?: 0L

    private fun playedMs(): Int {
        val t = track ?: return 0
        if (idle) return 0
        // Clamp to what this run actually wrote (the head can never legitimately
        // pass it; guards a mid-flush read too).
        val frames = (head.read(t) - runStartFrames).coerceIn(0L, runWrittenFrames)
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
        // Flush and re-zero the clock as one step: the writer thread reads
        // the head concurrently, and a read landing between the two would
        // have to GUESS whether the fresh 0 is a reset or a wrap.
        head.flush(t)
        t.play()   // ready for the next run
        return played
    }

    private fun dispose() {
        releaseTrack()
        // Only surrender call mode once the track is really gone.
        route.release()
    }

    private fun releaseTrack() {
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
        idle = true
        head.reset()
        runStartFrames = 0L
        runWrittenFrames = 0L
    }
}

/// AudioTrack.playbackHeadPosition widened to a monotonic 64-bit count.
///
/// The platform documents the head as an UNSIGNED 32-bit value that wraps, so
/// the frames advanced between two reads are the unsigned difference mod 2^32
/// — correct across a wrap as long as reads are less than 2^32 frames apart
/// (~49.7 h at 24 kHz; the writer alone reads every 100 ms). A difference in
/// the upper half of that range is not ~25 h of audio played between two
/// polls: it is the head going BACKWARDS, which means the track reset it
/// underneath us. That re-bases rather than adding 2^32 frames of nonsense.
///
/// Why extend rather than use AudioTrack.getTimestamp()'s 64-bit
/// framePosition: a timestamp is a sampled (position, time) pair that the
/// platform refreshes on its own schedule and does not return at all early in
/// playback or while paused — both states this clock is polled in — and its
/// reset on flush() is not documented. The head is what every caller here was
/// already built around.
///
/// Locked because the writer thread and the platform thread both read it,
/// and a read is a read-modify-write of [last]/[base].
private class HeadClock {
    private var base = 0L  // extended value at the last read
    private var last = 0L  // raw head at the last read, as unsigned

    @Synchronized fun read(t: AudioTrack): Long {
        val raw = t.playbackHeadPosition.toLong() and MASK
        val delta = (raw - last) and MASK
        base = if (delta < HALF) base + delta else raw
        last = raw
        return base
    }

    @Synchronized fun flush(t: AudioTrack) {
        t.flush()
        reset()
    }

    @Synchronized fun reset() {
        base = 0L
        last = 0L
    }

    private companion object {
        const val MASK = 0xFFFFFFFFL
        const val HALF = 0x80000000L
    }
}
