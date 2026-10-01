import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The device-facing side of the first-run permission prompt. A seam so the
/// flow's decisions can be tested without a phone.
abstract class PermissionGateway {
  Future<bool> alreadyPrompted();
  Future<void> markPrompted();
  Future<Map<Permission, PermissionStatus>> request(List<Permission> wanted);
}

class DevicePermissionGateway implements PermissionGateway {
  static const _key = 'first_run_permissions_prompted_v1';

  @override
  Future<bool> alreadyPrompted() async =>
      (await SharedPreferences.getInstance()).getBool(_key) ?? false;

  @override
  Future<void> markPrompted() async =>
      (await SharedPreferences.getInstance()).setBool(_key, true);

  @override
  Future<Map<Permission, PermissionStatus>> request(
          List<Permission> wanted) =>
      wanted.request();
}

enum PermissionPromptOutcome {
  /// Already asked on this install — never asked twice (no nagging).
  skipped,

  /// The person chose "Not now". Features still ask for what they need,
  /// at the moment they need it (e.g. joining a live asks for the microphone).
  declined,

  /// The system permission dialogs were shown.
  requested,
}

/// Asks for everything the app uses, once, right after sign-in — instead of
/// each permission surfacing as a surprise mid-feature.
class PermissionsFlow {
  PermissionsFlow(this.gateway, {required this.isAndroid});

  final PermissionGateway gateway;
  final bool isAndroid;

  /// What the app uses: camera + microphone (going live, audio rooms),
  /// notifications, and photos / audio files (profile pictures, and the
  /// host's own music in an audio room).
  ///
  /// permission_handler splits storage access by Android version: `storage`
  /// is the Android 12-and-below permission (it resolves to "denied" without
  /// prompting on 13+), `photos` and `audio` are the Android 13+ ones. Asking
  /// for all three covers every version.
  List<Permission> get wanted => [
        Permission.camera,
        Permission.microphone,
        Permission.notification,
        if (isAndroid) Permission.storage,
        Permission.photos,
        if (isAndroid) Permission.audio,
      ];

  /// [confirm] shows the explainer and returns whether the person agreed.
  Future<PermissionPromptOutcome> run({
    required Future<bool> Function() confirm,
  }) async {
    if (await gateway.alreadyPrompted()) return PermissionPromptOutcome.skipped;
    final agreed = await confirm();
    await gateway.markPrompted(); // asked once either way
    if (!agreed) return PermissionPromptOutcome.declined;
    await gateway.request(wanted);
    return PermissionPromptOutcome.requested;
  }
}
