package com.orbital.pai

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Local notifications (`MethodChannel("henry/notify")`: show / cancel / cancelAll /
/// requestPermission) for what arrives on the live socket while the app is backgrounded —
/// a timer going off, a household message, a reminder, a calendar heads-up. The Dart side
/// (`lib/notify/background_notices.dart`) decides WHEN; this only posts.
///
/// Framework APIs, not androidx `NotificationCompat`: minSdk is 26, so channels and
/// `Notification.Builder(context, channelId)` are always there, and the app module does not
/// otherwise depend on androidx.core.
///
/// Like [AlarmPlayer], it never touches audio: the notifications carry no sound of their own
/// beyond the channel default, and take no focus. [AudioRouteOwner] stays the only owner of
/// the mode and route.
class HenryNotifier(messenger: BinaryMessenger, private val activity: Activity) :
    MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "henry/notify")
    private val context: Context = activity.applicationContext
    private val manager = context.getSystemService(NotificationManager::class.java)

    /// The one outstanding permission request's reply, answered from
    /// [onRequestPermissionsResult]. Android shows one permission dialog at a time.
    private var pendingPermission: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler(this)
        createChannels()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "show" -> {
                show(
                    id = call.argument<Int>("id") ?: 0,
                    title = call.argument<String>("title") ?: "",
                    body = call.argument<String>("body") ?: "",
                    channelId = call.argument<String>("channel") ?: ALERTS,
                )
                result.success(null)
            }
            "cancel" -> {
                call.argument<Int>("id")?.let { manager.cancel(it) }
                result.success(null)
            }
            "cancelAll" -> {
                manager.cancelAll()
                result.success(null)
            }
            "requestPermission" -> requestPermission(result)
            else -> result.notImplemented()
        }
    }

    /// Idempotent: re-creating an existing channel only updates its name/description and never
    /// overrides what the user changed in system settings.
    private fun createChannels() {
        manager.createNotificationChannels(
            listOf(
                NotificationChannel(ALERTS, "Timers & reminders", NotificationManager.IMPORTANCE_HIGH)
                    .apply { description = "Timers going off, reminders and calendar heads-ups" },
                NotificationChannel(MESSAGES, "Messages", NotificationManager.IMPORTANCE_HIGH)
                    .apply { description = "Household messages Henry relays to you" },
            )
        )
    }

    private fun show(id: Int, title: String, body: String, channelId: String) {
        // Denied (or switched off in settings): degrade silently. Posting anyway is a no-op on
        // 33+ and noise in logcat.
        if (!manager.areNotificationsEnabled()) return
        val builder = Notification.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_stat_henry)
            .setColor(ACCENT)
            .setContentTitle(title)
            .setContentIntent(openApp())
            .setAutoCancel(true)
            // A late body (a reminder whose answer took a while) REPLACES the lead-only notice
            // under the same id; it must not buzz the phone a second time.
            .setOnlyAlertOnce(true)
            .setShowWhen(true)
            .setCategory(
                when (channelId) {
                    MESSAGES -> Notification.CATEGORY_MESSAGE
                    else -> Notification.CATEGORY_REMINDER
                }
            )
        if (body.isNotEmpty()) {
            builder.setContentText(body).setStyle(Notification.BigTextStyle().bigText(body))
        }
        manager.notify(id, builder.build())
    }

    /// Tap → the app, brought to the front (MainActivity is singleTop; the launcher's own
    /// intent finds the existing task rather than starting a second one).
    private fun openApp(): PendingIntent {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    /// Android 13+ asks; older versions answer from settings. Asked at most ONCE per install
    /// (remembered in prefs): a "no" is respected rather than re-prompted on every sign-in.
    private fun requestPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(manager.areNotificationsEnabled())
            return
        }
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getBoolean(ASKED, false) || pendingPermission != null) {
            result.success(false)
            return
        }
        pendingPermission = result
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_CODE)
    }

    /// Forwarded from [MainActivity.onRequestPermissionsResult]. True when it was ours.
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val reply = pendingPermission ?: return true
        pendingPermission = null
        // An EMPTY result is a cancelled request (another permission dialog was already up), not
        // an answer — leave "asked" unset so the next sign-in gets its one real chance.
        if (grantResults.isNotEmpty()) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean(ASKED, true).apply()
        }
        reply.success(
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        )
        return true
    }

    /// The engine is going away: nobody is left to answer.
    fun detach() {
        channel.setMethodCallHandler(null)
        pendingPermission?.success(false)
        pendingPermission = null
    }

    companion object {
        const val ALERTS = "henry_alerts"
        const val MESSAGES = "henry_messages"
        private const val PREFS = "henry_notify"
        private const val ASKED = "post_notifications_asked"
        private const val REQUEST_CODE = 0x4E4F // "NO"

        /// Henry's green (M.henry, #3ECF9A) for the small icon's tint.
        private const val ACCENT = 0xFF3ECF9A.toInt()
    }
}
