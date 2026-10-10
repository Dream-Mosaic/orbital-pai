package com.orbital.pai

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var player: AudioTrackPlayer? = null
    private var alarm: AlarmPlayer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        player = AudioTrackPlayer(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        alarm = AlarmPlayer(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // The engine (and the Dart side that would stop it) is going away.
        alarm?.stop()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
