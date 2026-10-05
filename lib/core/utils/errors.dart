import 'package:flutter/services.dart' show PlatformException;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Unwraps Supabase's exception types to their plain message instead of the
/// verbose `PostgrestException(message: ..., code: ...)` toString().
String friendlyError(Object error) => switch (error) {
      AuthException(:final message) => _authMessage(message),
      PostgrestException(:final message) => message,
      FunctionException() => _functionMessage(error),
      PlatformException() => _platformMessage(error),
      Exception() => error.toString().replaceFirst('Exception: ', ''),
      _ => error.toString(),
    };

String _authMessage(String message) =>
    message.toLowerCase().contains('banned')
        ? 'This account has been banned.'
        : message;

/// The edge functions answer errors as `{"error": "...", "code": "..."}`.
String _functionMessage(FunctionException e) {
  final details = e.details;
  if (details is Map && details['error'] is String) {
    return details['error'] as String;
  }
  if (details is String && details.trim().isNotEmpty) return details;
  return e.reasonPhrase ?? 'The request failed (${e.status}).';
}

/// SQLSTATEs the database raises for the ban system. (BN003, "can't message
/// this user", needs no handling: its message is already readable.)
const banCode = 'BN001'; // banned (account, live or device)
const removedCode = 'BN002'; // removed from a live by the host / blocked by them

String? _codeOf(Object error) => switch (error) {
      PostgrestException(:final code) => code,
      FunctionException(:final details) =>
        details is Map ? details['code'] as String? : null,
      _ => null,
    };

/// True when [error] means the user may not be in this live (banned, or removed
/// by the host) — as opposed to an ordinary failure worth ignoring or retrying.
bool isLiveAccessError(Object error) {
  final code = _codeOf(error);
  return code == banCode || code == removedCode;
}

/// A device-side failure (a plugin that did not answer, Play Services refusing) should
/// never reach a person as `PlatformException(channel-error, Unable to establish
/// connection on channel: "dev.flutter.pigeon...`.
String _platformMessage(PlatformException e) => switch (e.code) {
      'channel-error' ||
      'sign_in_failed' =>
        "Google sign-in isn't available on this phone right now. Use your email or phone number instead.",
      'network_error' => 'Check your internet connection and try again.',
      _ => (e.message?.trim().isNotEmpty ?? false)
          ? e.message!
          : 'Something went wrong on this device. Please try again.',
    };

/// True when the on-device Google sign-in itself could not run (its plugin did not
/// answer, or Play Services refused the request) — the person did not cancel and it is
/// not a network problem — so the browser-based Google sign-in should be tried instead.
bool googleNativeSignInUnavailable(Object error) =>
    error is PlatformException &&
    (error.code == 'channel-error' || error.code == 'sign_in_failed');
