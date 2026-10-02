import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/google_config.dart';
import '../config/supabase_client.dart';
import '../config/supabase_config.dart';
import '../data/models.dart';
import '../data/restrictions_repository.dart';
import '../services/device_identity_service.dart';
import '../services/push_notifications_service.dart';
import 'access_guard.dart';
import 'staff_account_gate.dart';

enum AuthStatus { unknown, onboarding, unauthenticated, authenticated }

/// Real Supabase-backed auth. Session persistence, restore, and refresh are
/// handled by supabase_flutter; this class layers app-specific status
/// (splash/onboarding/auth-flow/main-shell) and the `profiles` row on top.
class AuthController extends ChangeNotifier {
  AuthController() {
    _authSub = supabase.auth.onAuthStateChange.listen(_onAuthEvent);
  }

  AuthStatus _status = AuthStatus.unknown;
  AppUser? _user;
  bool _busy = false;
  String? _pendingPhone;
  // Set only while the OTP flow is between verifyOtp() and finishAuth(), so
  // the success screen gets its moment before the app flips to the home
  // shell. Every other sign-in path (password, signup, and — critically —
  // OAuth's deep-link return) has no such screen and must flip immediately.
  bool _awaitingOtpFinish = false;
  StreamSubscription<AuthState>? _authSub;

  /// Keeps admin-panel accounts out of the app — see [StaffAccountGate].
  final StaffAccountGate _gate = StaffAccountGate(
    lookup: _lookupIsStaff,
    cache: DeviceVerifiedUserCache(),
  );

  /// Asks the server whether this account / device is banned — see
  /// [AccessGuard]. Bans are enforced by the database; this lets the app react.
  final RestrictionsRepository _restrictionsRepo = RestrictionsRepository();
  late final AccessGuard _access = AccessGuard(
    fetch: _restrictionsRepo.mine,
    registerDevice: () async => _restrictionsRepo.registerDevice(
      await DeviceIdentityService.instance.load(),
    ),
  );
  Restrictions _restrictions = Restrictions.none;
  String? _notice;
  RealtimeChannel? _bansChannel;
  String? _bansChannelUser;
  bool _endingForBan = false;

  AuthStatus get status => _status;
  AppUser? get user => _user;

  /// What currently restricts this user (a live ban, say). Changes the moment a
  /// ban is placed or lifted from the panel.
  Restrictions get restrictions => _restrictions;

  /// Why the user was just signed out (e.g. their account was banned), for the
  /// login screen to show once.
  String? get notice => _notice;
  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }
  bool get busy => _busy;
  String get pendingPhone => _pendingPhone ?? '';

  Future<void> _onAuthEvent(AuthState state) async {
    final session = state.session;
    if (session == null) {
      _stopWatchingBans();
      _access.reset();
      _restrictions = Restrictions.none;
      if (_status == AuthStatus.authenticated) {
        _user = null;
        _status = AuthStatus.unauthenticated;
        notifyListeners();
      }
      return;
    }
    // Admin-panel accounts (super_admin/admin/global_admin/country_admin/
    // sub_admin/agency_manager) share the same Supabase project as the app
    // but must never actually use it — sign them back out immediately. This
    // is the single chokepoint every session-creating path funnels through
    // (password, Google, OAuth redirect return, a restored cold-start
    // session, and OTP), so it's the one place this needs to live.
    final verdict = await _gate.check(
      session.user.id,
      appMetadata: session.user.appMetadata,
    );
    if (verdict == StaffGateVerdict.staff) {
      await supabase.auth.signOut();
      return;
    }
    // Couldn't check and never verified: don't let it in (the session itself
    // is left alone — a transient network error shouldn't sign anyone out).
    if (verdict == StaffGateVerdict.unverified) return;
    // A banned account (or a banned phone) is signed out with the reason.
    // (During an explicit sign-in the sign-in method itself ends the session and
    // throws the reason, so the handler only holds back from entering the app.)
    if (await _enforceBan(session.user.id, notice: true, endSession: !_busy) !=
        null) {
      return;
    }
    // Session exists (sign-in, token refresh, restored on cold start, or —
    // importantly — the OAuth deep-link returning after Google/Apple).
    await _refreshProfile(session.user.id);
    unawaited(PushNotificationsService.instance.registerForCurrentUser());
    // While still on the splash screen, a restored session fires here
    // almost immediately after boot — leave the first navigation away from
    // it to completeSplash() (driven by the intro video finishing, its
    // timeout, or a tap-to-skip), which already re-checks currentSession
    // itself. Without this guard the splash gets cut short for any
    // returning, already-logged-in user as soon as the profile fetch above
    // resolves.
    if (_status == AuthStatus.unknown) return;
    if (!_awaitingOtpFinish && _status != AuthStatus.authenticated) {
      _status = AuthStatus.authenticated;
      notifyListeners();
    }
  }

  static Future<bool> _lookupIsStaff(String userId) async {
    final row = await supabase
        .from('staff_roles')
        .select('user_id')
        .eq('user_id', userId)
        .maybeSingle();
    return row != null;
  }

  /// For an explicit sign-in (password, Google, OTP): a panel account — or one
  /// that can't be checked — is signed straight back out with a clear message.
  Future<void> _requireNormalUser(User user) async {
    final verdict = await _gate.check(user.id, appMetadata: user.appMetadata);
    final message = StaffAccountGate.messageFor(verdict);
    if (message == null) return;
    await supabase.auth.signOut();
    throw Exception(message);
  }

  /// Checks the user against the ban system. If the whole app is closed to them
  /// (ID ban or banned device) they are signed out and the reason is returned;
  /// otherwise null, and a live watch on their ban rows begins so a ban placed
  /// later reaches them at once. [notice] says whether the login screen should
  /// show the reason (not needed when an explicit sign-in is about to throw it).
  Future<String?> _enforceBan(
    String userId, {
    required bool notice,
    bool endSession = true,
  }) async {
    final check = await _access.check(userId);
    _setRestrictions(check.restrictions);
    final message = check.blockedMessage;
    if (message != null) {
      if (endSession) await _endSessionForBan(message, notice: notice);
      return message;
    }
    _watchBans(userId);
    return null;
  }

  void _setRestrictions(Restrictions next) {
    if (next == _restrictions) return;
    _restrictions = next;
    notifyListeners();
  }

  Future<void> _endSessionForBan(String message, {required bool notice}) async {
    if (_endingForBan) return;
    _endingForBan = true;
    try {
      if (notice) _notice = message;
      _stopWatchingBans();
      try {
        await PushNotificationsService.instance.onSignOut();
      } catch (_) {}
      await _signOutOfGoogle();
      await supabase.auth.signOut();
      _access.reset();
      _restrictions = Restrictions.none;
      _user = null;
      // at the splash screen completeSplash() decides where to go next
      if (_status != AuthStatus.unknown) _status = AuthStatus.unauthenticated;
      _awaitingOtpFinish = false;
      notifyListeners();
    } finally {
      _endingForBan = false;
    }
  }

  void _watchBans(String userId) {
    if (_bansChannelUser == userId) return;
    _stopWatchingBans();
    _bansChannelUser = userId;
    _bansChannel = _restrictionsRepo.watchMine(userId, () async {
      // re-read from the server rather than trusting the payload
      _access.reset();
      await _enforceBan(userId, notice: true);
    });
  }

  void _stopWatchingBans() {
    _bansChannel?.unsubscribe();
    _bansChannel = null;
    _bansChannelUser = null;
  }

  /// Before any sign-in or sign-up: a banned phone can't even start one.
  /// Fails open if the server can't be reached.
  Future<void> _requireDeviceAllowed() async {
    String? message;
    try {
      final device = await DeviceIdentityService.instance.load();
      final ban = await _restrictionsRepo.checkDevice(device.id);
      if (ban != null && ban.isActive()) {
        message = 'This device is banned ${ban.phrase}.';
      }
    } catch (_) {}
    if (message != null) throw Exception(message);
  }

  Future<void> _refreshProfile(String userId) async {
    final row = await supabase
        .from('profiles')
        .select()
        .eq('id', userId)
        .maybeSingle();
    if (row != null) {
      _user = AppUser.fromRow(row);
      notifyListeners();
    }
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    _busy = true;
    notifyListeners();
    try {
      return await body();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> completeSplash() async {
    if (_status != AuthStatus.unknown) return;
    final session = supabase.auth.currentSession;
    if (session == null) {
      _status = AuthStatus.onboarding;
      notifyListeners();
      return;
    }
    // A restored session only enters the app once it has passed the staff
    // gate. (It used to be marked authenticated first and checked afterwards,
    // so a panel account was briefly inside the app.)
    final verdict = await _gate.check(
      session.user.id,
      appMetadata: session.user.appMetadata,
    );
    if (_status != AuthStatus.unknown) return; // the event handler got there first
    switch (verdict) {
      case StaffGateVerdict.allowed:
        final banMessage = await _enforceBan(session.user.id, notice: true);
        if (_status != AuthStatus.unknown) return;
        if (banMessage != null) {
          _status = AuthStatus.unauthenticated;
          notifyListeners();
          return;
        }
        _status = AuthStatus.authenticated;
        notifyListeners();
        unawaited(_refreshProfile(session.user.id));
      case StaffGateVerdict.staff:
        await supabase.auth.signOut();
        _status = AuthStatus.unauthenticated;
        notifyListeners();
      case StaffGateVerdict.unverified:
        _status = AuthStatus.unauthenticated;
        notifyListeners();
    }
  }

  void completeOnboarding() {
    _status = AuthStatus.unauthenticated;
    notifyListeners();
  }

  Future<void> loginWithPassword(String id, String password) =>
      _guard(() async {
        clearNotice();
        await _requireDeviceAllowed();
        final trimmed = id.trim();
        if (trimmed.contains('@')) {
          await supabase.auth.signInWithPassword(
            email: trimmed,
            password: password,
          );
        } else {
          await supabase.auth.signInWithPassword(
            phone: trimmed,
            password: password,
          );
        }
        final user = supabase.auth.currentUser!;
        await _requireNormalUser(user);
        final banned = await _enforceBan(user.id, notice: false);
        if (banned != null) throw Exception(banned);
        await _refreshProfile(user.id);
        _status = AuthStatus.authenticated;
        notifyListeners();
      });

  /// Google uses the native on-device account picker (Play Services' own
  /// "Choose an account" sheet) once GoogleConfig.webClientId is filled in
  /// — until then, it transparently falls back to the same web-redirect
  /// OAuth flow Apple/Facebook already use (the "earlier way"), rather
  /// than throwing. That fallback is deliberate: this line doesn't need
  /// touching again once the Google Cloud + Supabase dashboard setup
  /// (see google_config.dart's own doc comment) is actually done — it just
  /// starts using the native picker the moment isConfigured flips true.
  Future<void> loginWithSocial(String provider) => _guard(() async {
    clearNotice();
    await _requireDeviceAllowed();
    if (provider == 'Google' && GoogleConfig.isConfigured) {
      final googleUser = await GoogleSignIn(
        serverClientId: GoogleConfig.webClientId,
      ).signIn();
      if (googleUser == null) return; // user cancelled the native picker
      final googleAuth = await googleUser.authentication;
      final idToken = googleAuth.idToken;
      if (idToken == null) {
        throw Exception('Google sign-in did not return an ID token');
      }
      await supabase.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: googleAuth.accessToken,
      );
      final user = supabase.auth.currentUser!;
      await _requireNormalUser(user);
      final banned = await _enforceBan(user.id, notice: false);
      if (banned != null) throw Exception(banned);
      await _refreshProfile(user.id);
      _status = AuthStatus.authenticated;
      notifyListeners();
      return;
    }
    final oauth = switch (provider) {
      'Google' => OAuthProvider.google,
      'Apple' => OAuthProvider.apple,
      _ => OAuthProvider.facebook,
    };
    await supabase.auth.signInWithOAuth(
      oauth,
      redirectTo: SupabaseConfig.authRedirectUrl,
    );
  });

  /// Step 1 of the phone flow — sends a real OTP. Requires an SMS provider
  /// to be configured in the Supabase dashboard (Auth → Providers → Phone);
  /// throws otherwise.
  Future<void> requestOtp(String phone) => _guard(() async {
    clearNotice();
    await _requireDeviceAllowed();
    _pendingPhone = phone;
    await supabase.auth.signInWithOtp(phone: phone);
  });

  /// Step 2 — verifies against Supabase. Does not flip to authenticated yet
  /// so the OTP screen's success state can show first; call [finishAuth].
  Future<bool> verifyOtp(String code) => _guard(() async {
    final phone = _pendingPhone;
    if (phone == null) return false;
    _awaitingOtpFinish = true;
    final res = await supabase.auth.verifyOTP(
      phone: phone,
      token: code,
      type: OtpType.sms,
    );
    if (res.session != null) {
      try {
        await _requireNormalUser(res.session!.user);
        final banned = await _enforceBan(res.session!.user.id, notice: false);
        if (banned != null) throw Exception(banned);
      } catch (_) {
        _awaitingOtpFinish = false; // signed back out; nothing to finish
        rethrow;
      }
      await _refreshProfile(res.session!.user.id);
      return true;
    }
    _awaitingOtpFinish = false;
    return false;
  });

  void finishAuth() {
    _awaitingOtpFinish = false;
    // never enter the app without a live session (e.g. one the gate just ended)
    if (_user == null || supabase.auth.currentSession == null) return;
    _status = AuthStatus.authenticated;
    notifyListeners();
  }

  /// Returns `true` when the account was created but needs email confirmation
  /// before the user can sign in (no session yet).
  Future<bool> signUp({
    required String name,
    required String email,
    required String username,
    required String password,
  }) => _guard(() async {
    await _requireDeviceAllowed();
    final res = await supabase.auth.signUp(
      email: email.trim(),
      password: password,
      data: {'name': name.trim(), 'username': username.trim()},
    );
    final uid = supabase.auth.currentUser?.id;
    if (res.session != null && uid != null) {
      await _refreshProfile(uid);
      _status = AuthStatus.authenticated;
      notifyListeners();
      return false;
    }
    return true; // pending email confirmation
  });

  Future<void> resetPassword(String target) => _guard(() async {
    await supabase.auth.resetPasswordForEmail(target.trim());
  });

  // Username is admin/agency-controlled, not user-editable — it's the
  // lookup key for coin transfers (resell_coins), so a user renaming
  // themselves could cause misdirected transfers. Enforced server-side
  // too (see migration 20260921100000_lock_username_edit.sql), this just
  // keeps the client from offering a control that wouldn't do anything.
  Future<void> updateProfile({
    String? name,
    String? bio,
    String? location,
    String? gender,
    DateTime? dateOfBirth,
    int? pkWallpaper,
  }) => _guard(() async {
    final uid = supabase.auth.currentUser;
    if (uid == null) return;
    final updates = <String, dynamic>{
      'name': ?name,
      'bio': ?bio,
      'location': ?location,
      'gender': ?gender,
      if (dateOfBirth != null)
        'date_of_birth': dateOfBirth.toIso8601String().split('T').first,
      'pk_wallpaper': ?pkWallpaper,
    };
    if (updates.isEmpty) return;
    await supabase.from('profiles').update(updates).eq('id', uid.id);
    await _refreshProfile(uid.id);
  });

  /// Uploads [bytes] to the `avatars` storage bucket at `<uid>/avatar.<ext>`
  /// (upsert — same path every time, so old photos don't pile up) and points
  /// `profiles.avatar_url` at its public URL. A cache-busting query param is
  /// appended so the new photo shows immediately everywhere `AppAvatar` is
  /// used, instead of every client serving a stale cached copy of the same URL.
  Future<void> uploadAvatar(List<int> bytes, {required String extension}) =>
      _guard(() async {
        final uid = supabase.auth.currentUser;
        if (uid == null) return;
        final path = '${uid.id}/avatar.$extension';
        await supabase.storage
            .from('avatars')
            .uploadBinary(
              path,
              Uint8List.fromList(bytes),
              fileOptions: FileOptions(
                contentType: 'image/$extension',
                upsert: true,
              ),
            );
        final publicUrl = supabase.storage.from('avatars').getPublicUrl(path);
        final bustedUrl =
            '$publicUrl?v=${DateTime.now().millisecondsSinceEpoch}';
        await supabase
            .from('profiles')
            .update({'avatar_url': bustedUrl})
            .eq('id', uid.id);
        await _refreshProfile(uid.id);
      });

  Future<void> signOut() => _guard(() async {
    await PushNotificationsService.instance.onSignOut();
    await _signOutOfGoogle();
    await supabase.auth.signOut();
    _stopWatchingBans();
    _access.reset();
    _restrictions = Restrictions.none;
    _user = null;
    _status = AuthStatus.unauthenticated;
    _awaitingOtpFinish = false;
    notifyListeners();
  });

  /// Logs a deletion request (`account_deletion_requests`) and signs out.
  /// Actual deletion is a manual admin-panel action, per Google Play /
  /// Apple's account-deletion requirements.
  Future<void> requestAccountDeletion({String? reason}) => _guard(() async {
    await supabase.rpc(
      'request_account_deletion',
      params: {'p_reason': reason},
    );
    await PushNotificationsService.instance.onSignOut();
    await _signOutOfGoogle();
    await supabase.auth.signOut();
    _stopWatchingBans();
    _access.reset();
    _restrictions = Restrictions.none;
    _user = null;
    _status = AuthStatus.unauthenticated;
    notifyListeners();
  });

  /// google_sign_in's own doc comment on signIn() spells out exactly why
  /// this is needed: "Authentication process is triggered only if there is
  /// no currently signed in user... otherwise this method returns the same
  /// user instance. Re-authentication can be triggered only after signOut
  /// or disconnect." We never called either, so Play Services kept
  /// resolving every future signIn() to whichever Google account was used
  /// first — no picker, no way to switch accounts, even across app
  /// reinstalls/rebuilds, since the cache lives with Play Services on the
  /// device, not in the app build. Safe to call unconditionally even for a
  /// password/phone/Apple session that never touched Google sign-in.
  Future<void> _signOutOfGoogle() async {
    try {
      await GoogleSignIn().signOut();
    } catch (_) {}
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _stopWatchingBans();
    super.dispose();
  }
}
