package com.sabalive.`in`

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Screenshot / screen-recording protection: FLAG_SECURE makes the system show a black picture instead of this
        // window to screenshots, screen recorders, casting and the recent-apps thumbnail. The Dart side decides when
        // (a switch in the admin panel); see lib/services/screen_protection.dart.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sabalive.in/screen_protection")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecure" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        runOnUiThread {
                            if (on) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
