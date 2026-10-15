package com.sabalive.`in`

import android.media.MediaDrm
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest
import java.util.UUID

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

        // A hardware-backed device id for bans: the Widevine DRM device id outlives a factory reset (the Android id does
        // not). Only a SHA-256 of it leaves the phone; null when the phone has no Widevine DRM. See
        // lib/services/device_identity_service.dart.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sabalive.in/device_ids")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "drmId" -> result.success(drmDeviceId())
                    else -> result.notImplemented()
                }
            }
    }

    private fun drmDeviceId(): String? {
        return try {
            val widevine = UUID(-0x121074568629b532L, -0x5c37d8232ae2de13L)
            val drm = MediaDrm(widevine)
            try {
                val raw = drm.getPropertyByteArray(MediaDrm.PROPERTY_DEVICE_UNIQUE_ID)
                MessageDigest.getInstance("SHA-256").digest(raw).joinToString("") { "%02x".format(it) }
            } finally {
                drm.release()
            }
        } catch (e: Exception) {
            null
        }
    }
}
