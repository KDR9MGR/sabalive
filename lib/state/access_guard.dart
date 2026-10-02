import '../data/restrictions_repository.dart';

/// The outcome of checking one signed-in user against the ban system.
class AccessCheck {
  const AccessCheck({required this.restrictions, this.blockedMessage});

  /// What currently restricts the user (live bans included).
  final Restrictions restrictions;

  /// Non-null when the whole app is closed to them (ID ban or banned device) —
  /// the text to show after signing them out.
  final String? blockedMessage;

  bool get blocked => blockedMessage != null;

  static const open = AccessCheck(restrictions: Restrictions.none);
}

/// Asks the server whether a signed-in user — or the phone they're on — is
/// banned, once per user per sign-in.
///
/// The database is what actually enforces bans, and it keeps doing so whatever
/// this says; this only lets the app react (sign out, say why, close a live). So
/// unlike the staff-account gate it **fails open**: if the server can't be
/// reached the user isn't kept out, and the next sign-in event tries again.
class AccessGuard {
  AccessGuard({
    required Future<Restrictions> Function() fetch,
    required Future<BanInfo?> Function() registerDevice,
    DateTime Function()? clock,
    this.timeout = const Duration(seconds: 4),
  }) : _fetch = fetch,
       _registerDevice = registerDevice,
       _clock = clock ?? DateTime.now;

  /// Don't hold the splash screen or a sign-in longer than this; past it the
  /// user goes through (fail open) and the server still enforces.
  final Duration timeout;

  final Future<Restrictions> Function() _fetch;
  final Future<BanInfo?> Function() _registerDevice;
  final DateTime Function() _clock;

  String? _userId;
  Future<AccessCheck>? _inflight;

  /// Same user -> the same answer (and one round trip) however many times the
  /// auth stream and the login screen both ask.
  Future<AccessCheck> check(String userId) {
    if (_userId == userId && _inflight != null) return _inflight!;
    _userId = userId;
    return _inflight = _run(userId);
  }

  Future<AccessCheck> _run(String userId) async {
    try {
      final (banned, restrictions) = await (() async {
        final banned = await _registerDevice();
        return (banned, await _fetch());
      })().timeout(timeout);
      final now = _clock();
      final message = banned != null && banned.isActive(now)
          ? 'This device is banned ${banned.phrase}.'
          : restrictions.appBlockMessage(now);
      return AccessCheck(restrictions: restrictions, blockedMessage: message);
    } catch (_) {
      // fail open — and forget this attempt so the next event retries
      if (_userId == userId) {
        _userId = null;
        _inflight = null;
      }
      return AccessCheck.open;
    }
  }

  /// Forget the current user (sign-out), so the next sign-in is checked afresh.
  void reset() {
    _userId = null;
    _inflight = null;
  }
}
