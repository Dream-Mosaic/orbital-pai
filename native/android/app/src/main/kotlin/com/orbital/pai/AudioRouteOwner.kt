package com.orbital.pai

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi

/// The ONE owner of the process's audio mode, communication route and audio
/// focus while a Henry session is live.
///
/// Why a class of its own rather than more of AudioTrackPlayer: this state
/// used to have two owners (the player here, and record_android's
/// AudioRecorder/BluetoothReceiver), and the result was order-dependent — the
/// mode and SCO depended on which side touched them last. The player's job is
/// PCM; keeping mode/route/focus in one small class, with the recorder
/// configured to keep its hands off all three (mic_capture.dart's config), is
/// what makes "one owner" a structural fact instead of a convention.
///
/// Main-thread only. Every entry point is either a method-channel call
/// (delivered on the main looper) or a listener registered on it; the player's
/// writer thread goes through [requestCheck], which posts. No locks, because
/// nothing here is ever touched from two threads.
class AudioRouteOwner(private val context: Context) {
    private val audio =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())

    private var acquired = false

    /// HELD, or temporarily taken by someone who will give it back (a phone
    /// call, a navigation prompt) — the system returns it with AUDIOFOCUS_GAIN
    /// — or LOST for good, which the system never undoes: only a fresh
    /// request gets it back.
    private enum class Focus { HELD, TRANSIENT_LOSS, LOST }
    private var focus = Focus.LOST
    private var focusRequest: AudioFocusRequest? = null

    /// Below API 31 there is no setCommunicationDevice, and with record's
    /// manageBluetooth off nobody else starts SCO, so the owner does. Tracked
    /// so we only ever stop an SCO link WE started.
    private var scoStarted = false

    /// Take the session: call mode, a route, focus. Idempotent — the player
    /// re-inits its track without releasing, and a second acquire must not
    /// bounce the mode (routing drops to the earpiece for the gap).
    fun acquire() {
        if (acquired) {
            reassertIfLost()
            return
        }
        acquired = true
        // Mode FIRST: it is what arms the platform AEC/NS against our own
        // playback, and on API < 31 SCO only carries voice in call mode.
        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        route()
        audio.registerAudioDeviceCallback(routeWatcher, main)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // The MAIN executor, not a direct one: AudioManager calls this
            // listener from a binder thread, and this class is main-only.
            audio.addOnModeChangedListener(context.mainExecutor, modeWatcher)
        }
        requestFocus()
    }

    /// Hand everything back so the device is not left stuck in call mode
    /// (media volume, earpiece routing) after Henry is torn down.
    fun release() {
        if (!acquired) return
        // Before the mode write below: the mode watcher would otherwise see
        // MODE_NORMAL and put us straight back into call mode.
        acquired = false
        main.removeCallbacksAndMessages(null)
        audio.unregisterAudioDeviceCallback(routeWatcher)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audio.removeOnModeChangedListener(modeWatcher)
            audio.clearCommunicationDevice()
        } else {
            stopSco()
            @Suppress("DEPRECATION")
            audio.isSpeakerphoneOn = false
        }
        focusRequest?.let { audio.abandonAudioFocusRequest(it) }
        focusRequest = null
        focus = Focus.LOST
        audio.mode = AudioManager.MODE_NORMAL
    }

    /// Safe from any thread. The player calls it when an answer starts
    /// playing: on API < 31 there is no mode-change callback, so the start of
    /// every answer is the fallback moment to notice the mode was taken and
    /// take it back — the one moment it audibly matters.
    fun requestCheck() {
        main.post { reassertIfLost() }
    }

    /// Put back whatever was taken while we were not looking.
    ///
    /// ONLY from MODE_NORMAL. Any other mode means someone is using it right
    /// now — the phone (RINGTONE, IN_CALL), another VoIP app (its own
    /// IN_COMMUNICATION) — and overwriting that would break their call to fix
    /// ours. NORMAL means whoever took it has finished with it, which is
    /// exactly the "call ended" edge.
    private fun reassertIfLost() {
        if (!acquired) return
        if (audio.mode == AudioManager.MODE_NORMAL) {
            audio.mode = AudioManager.MODE_IN_COMMUNICATION
            // A mode change can reset routing, and a pinned communication
            // device may have been cleared by whoever held the mode.
            route()
        }
        // Permanent loss: the system will never hand it back on its own. We
        // are about to speak, so asking again is the right moment.
        if (focus == Focus.LOST) requestFocus()
    }

    // ---- focus ------------------------------------------------------------

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                focus = Focus.HELD
                // The fallback for API < 31, and belt-and-braces above it:
                // focus coming back is the end of whatever took it. Checked
                // again shortly after, because telephony's focus abandon and
                // its return to MODE_NORMAL are not ordered — the first check
                // can still see IN_CALL.
                reassertIfLost()
                main.postDelayed({ reassertIfLost() }, RECHECK_AFTER_GAIN_MS)
            }
            AudioManager.AUDIOFOCUS_LOSS -> focus = Focus.LOST
            // Deliberately no mic pause/duck here: whether Henry should stop
            // listening during someone else's audio is a conversation decision,
            // not a routing one, and it lives in Dart if anywhere.
            else -> focus = Focus.TRANSIENT_LOSS
        }
    }

    private fun requestFocus() {
        // GAIN_TRANSIENT_MAY_DUCK. The player is initialised on join and lives
        // for the whole connection — including the long wake-word idle
        // between conversations — so this request is held for as long as the
        // app is open. Plain GAIN tells other apps the loss is permanent (most
        // music players stay stopped even after we abandon); GAIN_TRANSIENT
        // pauses the user's music for as long as Henry is merely connected.
        // Ducking lets it play on, quieter, and still makes us a focus holder,
        // which is the point: a phone call's focus request reaches us as a
        // transient loss, and its end as AUDIOFOCUS_GAIN (the reassert
        // trigger below API 31).
        val request = focusRequest ?: AudioFocusRequest.Builder(
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build())
            // Starting Henry during a phone call: be queued, and handed focus
            // (and so a reassert) the moment the call ends, instead of failing.
            .setAcceptsDelayedFocusGain(true)
            .setOnAudioFocusChangeListener(focusListener, main)
            .build()
            .also { focusRequest = it }
        focus = when (audio.requestAudioFocus(request)) {
            AudioManager.AUDIOFOCUS_REQUEST_GRANTED -> Focus.HELD
            AudioManager.AUDIOFOCUS_REQUEST_DELAYED -> Focus.TRANSIENT_LOSS
            else -> Focus.LOST
        }
    }

    // ---- mode (API 31+) ---------------------------------------------------

    @get:RequiresApi(Build.VERSION_CODES.S)
    private val modeWatcher by lazy {
        AudioManager.OnModeChangedListener { reassertIfLost() }
    }

    // ---- route ------------------------------------------------------------

    /// Re-routes whenever something is plugged in or unplugged.
    /// setCommunicationDevice PINS a route, so without this, earbuds connected
    /// mid-answer would be ignored for the rest of the session.
    private val routeWatcher = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>?) = route()
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>?) = route()
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
        if (!acquired) return
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
            routeLegacy()
        }
    }

    /// API 26-30. There is no device pin, so the route is steered with the
    /// old global switches: SCO for a Bluetooth headset (record_android used
    /// to start it; with its manageBluetooth off, nothing else will), the
    /// speakerphone when there is no headset at all. A wired headset wins
    /// over Bluetooth: plugging a cable in is the more deliberate act.
    @Suppress("DEPRECATION")
    private fun routeLegacy() {
        val outs = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val wired = outs.any {
            it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                it.type == AudioDeviceInfo.TYPE_USB_HEADSET
        }
        val sco = !wired && audio.isBluetoothScoAvailableOffCall &&
            outs.any { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
        if (sco) startSco() else stopSco()
        audio.isSpeakerphoneOn = !(wired || sco)
    }

    @Suppress("DEPRECATION")
    private fun startSco() {
        if (scoStarted) return
        audio.startBluetoothSco()
        audio.isBluetoothScoOn = true
        scoStarted = true
    }

    @Suppress("DEPRECATION")
    private fun stopSco() {
        if (!scoStarted) return
        audio.isBluetoothScoOn = false
        audio.stopBluetoothSco()
        scoStarted = false
    }

    private companion object {
        const val RECHECK_AFTER_GAIN_MS = 1000L
    }
}
