package com.orbital.pai

import android.content.Context
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// The timer alarm (`MethodChannel("henry/alarm")`: start / stop): the device's
/// own alarm tone, looped, plus a repeating vibration.
///
/// What it deliberately does NOT do: request audio focus, or touch the audio
/// mode, the communication device, or SCO. Those have exactly one owner,
/// [AudioRouteOwner], for as long as the voice session is live (commit 1828d70
/// is the story of what two owners did). A [Ringtone] plays through its own
/// MediaPlayer and never asks for focus; tagged USAGE_ALARM, the platform routes
/// it to the speaker on its own policy without our route changing. So the mic
/// and Henry's voice stream are untouched while it rings.
///
/// Bounded twice: the Dart side stops it after ~30 s, and this side caps itself
/// at [CAP_MS] too, so an engine that dies mid-ring cannot leave the phone
/// ringing. Main-thread only (method calls arrive on the main looper).
class AlarmPlayer(messenger: BinaryMessenger, private val context: Context) :
    MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "henry/alarm")
    private val main = Handler(Looper.getMainLooper())
    private var ringtone: Ringtone? = null

    private val capStop = Runnable { stop() }

    /// Below API 28 a Ringtone cannot loop; re-trigger it while ringing instead.
    private val relooper = object : Runnable {
        override fun run() {
            val r = ringtone ?: return
            if (!r.isPlaying) r.play()
            main.postDelayed(this, 1000)
        }
    }

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> { start(); result.success(null) }
            "stop" -> { stop(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    fun start() {
        // Restarting is idempotent: a second timer going off re-arms the cap.
        stopSound()
        main.removeCallbacks(capStop)
        ringtone = alarmTone()?.also { r ->
            r.audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                r.isLooping = true
            } else {
                main.postDelayed(relooper, 1000)
            }
            r.play()
        }
        // Tagged as an ALARM vibration: an untagged vibrate() from a backgrounded app (and a
        // screen-off app counts as backgrounded) is silently dropped by Android.
        vibrator()?.vibrate(
            VibrationEffect.createWaveform(PATTERN, 0),
            AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build()
        )
        main.postDelayed(capStop, CAP_MS)
    }

    fun stop() {
        main.removeCallbacks(capStop)
        stopSound()
        vibrator()?.cancel()
    }

    private fun stopSound() {
        main.removeCallbacks(relooper)
        ringtone?.stop()
        ringtone = null
    }

    /// The user's chosen alarm tone, else the stock alarm, else a notification
    /// or ringtone — some devices ship with no alarm sound set at all.
    private fun alarmTone(): Ringtone? {
        // getActualDefaultRingtoneUri is null when nothing is SET for that type; getDefaultUri
        // never is (it's a settings pointer that may resolve to silence), so it can't be the
        // fallback — chain the actual URIs and only then the pointer.
        val uri = RingtoneManager.getActualDefaultRingtoneUri(context, RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getActualDefaultRingtoneUri(context, RingtoneManager.TYPE_NOTIFICATION)
            ?: RingtoneManager.getActualDefaultRingtoneUri(context, RingtoneManager.TYPE_RINGTONE)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: return null
        return RingtoneManager.getRingtone(context, uri)
    }

    private fun vibrator(): Vibrator? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)
                ?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }

    companion object {
        private const val CAP_MS = 35_000L

        /// off, buzz, off, buzz — repeated from index 0.
        private val PATTERN = longArrayOf(0, 450, 250, 450, 900)
    }
}
