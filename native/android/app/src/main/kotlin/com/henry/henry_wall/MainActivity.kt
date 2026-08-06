package com.henry.henry_wall

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var player: AudioTrackPlayer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        player = AudioTrackPlayer(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    }
}
