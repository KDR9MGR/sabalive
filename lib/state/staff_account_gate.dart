import 'package:shared_preferences/shared_preferences.dart';

/// Admin-panel (staff) accounts share the Supabase project with the app but
/// must never use the app. This decides, for a signed-in session, whether it
/// may stay.
///
/// Three layers, in order:
///  1. The `is_staff` flag in the session's own `app_metadata` (kept in sync by
///     a database trigger on `staff_roles`, migration 20261002090000). Read
///     straight off the session — instant, offline-safe, no query to fail.
///  2. Otherwise a `staff_roles` lookup (covers a session issued before the flag
///     existed, or a role granted since).
///  3. If that lookup can't be made, FAIL CLOSED — unless this very account was
///     already verified as a normal user on this device, so a flaky network
///     never locks an ordinary user out of their own app.
///
/// Exception: an account whose `app_metadata` carries `staff_app_access: true`
/// may use the app even though it is staff. That flag is written only by the
/// server (migration 20261005180000) — a user can't edit their own app_metadata —
/// so it is a deliberate, per-account allowance, not something the client decides.
///
/// What this cannot do: the server has no way to tell the app from the panel at
/// sign-in (same project, same login endpoint), so this is enforced in the app.
enum StaffGateVerdict {
  /// A normal user — may stay.
  allowed,

  /// A panel account — sign out.
  staff,

  /// Couldn't be checked and wasn't verified before — don't let it in.
  unverified,
}

typedef StaffLookup = Future<bool> Function(String userId);

/// Remembers which account was last confirmed to be a normal user.
abstract class VerifiedUserCache {
  Future<bool> isVerified(String userId);
  Future<void> markVerified(String userId);
  Future<void> clear();
}

class DeviceVerifiedUserCache implements VerifiedUserCache {
  static const _key = 'verified_non_staff_user_v1';

  @override
  Future<bool> isVerified(String userId) async =>
      (await SharedPreferences.getInstance()).getString(_key) == userId;

  @override
  Future<void> markVerified(String userId) async =>
      (await SharedPreferences.getInstance()).setString(_key, userId);

  @override
  Future<void> clear() async =>
      (await SharedPreferences.getInstance()).remove(_key);
}

class StaffAccountGate {
  StaffAccountGate({required this.lookup, required this.cache});

  final StaffLookup lookup;
  final VerifiedUserCache cache;

  static const staffMessage =
      'This is an admin-panel account. Sign in through the admin panel instead.';
  static const unverifiedMessage =
      "Couldn't verify your account. Check your connection and try again.";

  /// The message to show for a verdict that must not proceed, or null when it may.
  static String? messageFor(StaffGateVerdict v) => switch (v) {
        StaffGateVerdict.allowed => null,
        StaffGateVerdict.staff => staffMessage,
        StaffGateVerdict.unverified => unverifiedMessage,
      };

  Future<StaffGateVerdict> check(
    String userId, {
    Map<String, dynamic>? appMetadata,
  }) async {
    if (appMetadata?['staff_app_access'] == true) {
      return StaffGateVerdict.allowed;
    }
    if (appMetadata?['is_staff'] == true) {
      await cache.clear();
      return StaffGateVerdict.staff;
    }
    try {
      if (await lookup(userId)) {
        await cache.clear();
        return StaffGateVerdict.staff;
      }
      await cache.markVerified(userId);
      return StaffGateVerdict.allowed;
    } catch (_) {
      return await cache.isVerified(userId)
          ? StaffGateVerdict.allowed
          : StaffGateVerdict.unverified;
    }
  }
}
