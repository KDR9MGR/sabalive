import 'dart:io' show Platform;
import 'dart:math';

import 'package:android_id/android_id.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Who this phone is, for device bans.
class DeviceIdentity {
  const DeviceIdentity({
    required this.id,
    required this.platform,
    this.model,
    this.extraIds = const [],
  });

  /// More ids for the same phone (Android: the hardware DRM id, `drm:...`). The DRM id survives a factory reset, which
  /// changes the Android id, so a ban found through either id spreads to the other (register_device_v2).
  final List<String> extraIds;

  /// Every id this phone answers to, the main one first.
  List<String> get allIds => [id, ...extraIds];

  /// Stable per device (and install-signing key on Android), prefixed with where
  /// it came from, e.g. `android:9774d56d682e549c`.
  final String id;
  final String platform;
  final String? model;
}

/// What the platform says about this device, before we turn it into an id.
class RawDeviceInfo {
  const RawDeviceInfo({required this.platform, this.rawId, this.model, this.hardwareId});
  final String platform;
  final String? rawId;
  final String? model;

  /// A hardware-backed id that outlives a factory reset (Android: SHA-256 of the DRM device id), or null.
  final String? hardwareId;
}

/// The id a device ban keys on: Android's ANDROID_ID, or iOS's
/// identifierForVendor. Both survive an app reinstall; both change on a factory
/// reset (and can be spoofed), so a device ban deters rather than guarantees.
/// When the platform gives nothing, a random id is made once and remembered —
/// weaker, since clearing app data replaces it.
class DeviceIdentityService {
  DeviceIdentityService({
    Future<RawDeviceInfo> Function()? reader,
    Future<SharedPreferences> Function()? prefs,
    Random? random,
  }) : _reader = reader ?? _readNative,
       _prefs = prefs ?? SharedPreferences.getInstance,
       _random = random ?? Random.secure();

  static final DeviceIdentityService instance = DeviceIdentityService();

  static const _installKey = 'install_device_id_v1';

  final Future<RawDeviceInfo> Function() _reader;
  final Future<SharedPreferences> Function() _prefs;
  final Random _random;
  DeviceIdentity? _cached;

  /// Set once [load] has run; read by code that can't await.
  DeviceIdentity? get current => _cached;

  Future<DeviceIdentity> load() async {
    final cached = _cached;
    if (cached != null) return cached;

    RawDeviceInfo raw;
    try {
      raw = await _reader();
    } catch (_) {
      raw = const RawDeviceInfo(platform: 'unknown');
    }

    var id = _clean(raw.rawId);
    if (id != null) {
      id = '${raw.platform}:$id';
    } else {
      final prefs = await _prefs();
      var installId = prefs.getString(_installKey);
      if (installId == null || installId.isEmpty) {
        installId = _randomId();
        await prefs.setString(_installKey, installId);
      }
      id = 'install:$installId';
    }
    final hardware = _clean(raw.hardwareId);
    return _cached = DeviceIdentity(
      id: id,
      platform: raw.platform,
      model: _clean(raw.model),
      extraIds: hardware == null ? const [] : ['drm:$hardware'],
    );
  }

  /// Trims; a blank value counts as missing.
  static String? _clean(String? v) {
    final s = v?.trim();
    if (s == null || s.isEmpty) return null;
    return s;
  }

  String _randomId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// The DRM-based hardware id from the native side (MainActivity.kt). Null when the phone has no Widevine DRM or the
  /// call fails: the ban then works on the Android id alone, exactly as before.
  static Future<String?> _hardwareId() async {
    try {
      final id = await const MethodChannel('com.sabalive.in/device_ids').invokeMethod<String>('drmId');
      return (id == null || id.isEmpty) ? null : id;
    } catch (_) {
      return null;
    }
  }

  static Future<RawDeviceInfo> _readNative() async {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final android = await info.androidInfo;
      return RawDeviceInfo(
        platform: 'android',
        rawId: await const AndroidId().getId(),
        model: android.model,
        hardwareId: await _hardwareId(),
      );
    }
    if (Platform.isIOS) {
      final ios = await info.iosInfo;
      return RawDeviceInfo(
        platform: 'ios',
        rawId: ios.identifierForVendor,
        model: ios.utsname.machine,
      );
    }
    return RawDeviceInfo(platform: Platform.operatingSystem);
  }
}
