package com.orbital.pai

import android.app.Activity
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Wall mode's window knobs (`MethodChannel("henry/window")`: setKeepScreenOn / setBrightness).
/// The Dart side (`lib/device/window_control.dart`, driven by `WallModeHost`) decides when;
/// this only turns them.
///
/// Neither needs a permission: `FLAG_KEEP_SCREEN_ON` holds the screen on only while this
/// window is in front, and `screenBrightness` overrides only this window's brightness — the
/// system setting is untouched, and `BRIGHTNESS_OVERRIDE_NONE` hands it straight back.
///
/// Like [AlarmPlayer] and [HenryNotifier], it never touches audio: [AudioRouteOwner] stays
/// the only owner of the mode and route. Window calls are UI-thread only; method calls
/// already arrive on the main looper, and `runOnUiThread` runs inline there.
class WindowChannel(messenger: BinaryMessenger, private val activity: Activity) :
    MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "henry/window")

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setKeepScreenOn" -> {
                setKeepScreenOn(call.argument<Boolean>("on") ?: false)
                result.success(null)
            }
            "setBrightness" -> {
                // A Number, not a Double: the codec hands an integral Dart double over as
                // whatever it encoded, and a null level means "the system's again".
                setBrightness((call.argument<Any>("level") as? Number)?.toFloat())
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun setKeepScreenOn(on: Boolean) = activity.runOnUiThread {
        if (on) {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    private fun setBrightness(level: Float?) = activity.runOnUiThread {
        val attrs = activity.window.attributes
        attrs.screenBrightness =
            level?.coerceIn(0f, 1f) ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
        activity.window.attributes = attrs
    }

    fun detach() {
        channel.setMethodCallHandler(null)
    }
}
