package com.orbital.pai

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var player: AudioTrackPlayer? = null
    private var alarm: AlarmPlayer? = null
    private var notifier: HenryNotifier? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        player = AudioTrackPlayer(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        alarm = AlarmPlayer(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        notifier = HenryNotifier(flutterEngine.dartExecutor.binaryMessenger, this)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // The engine (and the Dart side that would stop it) is going away.
        alarm?.stop()
        notifier?.detach()
        notifier = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        // Ours (POST_NOTIFICATIONS) is answered here; everything else (the record plugin's
        // microphone request) still reaches the plugins through super.
        notifier?.onRequestPermissionsResult(requestCode, grantResults)
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}
