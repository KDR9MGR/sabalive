import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

/// What the earlier device is told when the account signs in somewhere else.
const sessionReplacedMessage =
    'You were signed out because your account was signed in on another device.';

/// The `session_id` claim of a Supabase access token — the id of this sign-in.
/// Null if the token is missing or has no such claim.
String? sessionIdOf(String? accessToken) {
  if (accessToken == null) return null;
  final parts = accessToken.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final claims = jsonDecode(payload);
    final sid = claims is Map ? claims['session_id'] : null;
    return sid is String && sid.isNotEmpty ? sid : null;
  } catch (_) {
    return null;
  }
}

/// Has another device taken over the account? [row] is the account's
/// `user_active_session` row after a change. The sign-in id is compared when
/// both sides have one; otherwise the device id (which is the same for a device
/// signing back in on itself, so that is never mistaken for a takeover).
bool sessionWasReplaced(
  Map<String, dynamic> row, {
  String? mySessionId,
  String? myDeviceId,
}) {
  final rowSession = row['session_id'];
  if (mySessionId != null && rowSession is String) {
    return rowSession != mySessionId;
  }
  final rowDevice = row['device_id'];
  if (myDeviceId != null && rowDevice is String) {
    return rowDevice != myDeviceId;
  }
  return false;
}

/// How [user] signed in, as recorded in their login history: email, phone_otp,
/// google, apple, facebook. Taken from the identity they used most recently.
String loginMethodFor(User user) {
  UserIdentity? latest;
  for (final identity in user.identities ?? const <UserIdentity>[]) {
    final at = DateTime.tryParse(identity.lastSignInAt ?? '');
    final best = DateTime.tryParse(latest?.lastSignInAt ?? '');
    if (latest == null ||
        (at != null && (best == null || at.isAfter(best)))) {
      latest = identity;
    }
  }
  final provider = latest?.provider ?? user.appMetadata['provider'] as String?;
  return switch (provider) {
    'phone' => 'phone_otp',
    'email' || 'google' || 'apple' || 'facebook' => provider!,
    null => 'email',
    final other => other,
  };
}
