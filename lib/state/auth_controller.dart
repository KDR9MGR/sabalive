import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/google_config.dart';
import '../config/supabase_client.dart';
import '../config/supabase_config.dart';
import '../data/models.dart';
import '../services/push_notifications_service.dart';

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

  AuthStatus get status => _status;
  AppUser? get user => _user;
  bool get busy => _busy;
  String get pendingPhone => _pendingPhone ?? '';

  Future<void> _onAuthEvent(AuthState state) async {
    final session = state.session;
    if (session == null) {
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
    if (await _isStaffAccount(session.user.id)) {
      await supabase.auth.signOut();
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

  Future<bool> _isStaffAccount(String userId) async {
    final row = await supabase
        .from('staff_roles')
        .select('user_id')
        .eq('user_id', userId)
        .maybeSingle();
    return row != null;
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

  void completeSplash() {
    if (_status != AuthStatus.unknown) return;
    final session = supabase.auth.currentSession;
    if (session != null) {
      _status = AuthStatus.authenticated;
      notifyListeners();
      unawaited(_refreshProfile(session.user.id));
    } else {
      _status = AuthStatus.onboarding;
      notifyListeners();
    }
  }

  void completeOnboarding() {
    _status = AuthStatus.unauthenticated;
    notifyListeners();
  }

  Future<void> loginWithPassword(String id, String password) =>
      _guard(() async {
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
        final uid = supabase.auth.currentUser!.id;
        if (await _isStaffAccount(uid)) {
          await supabase.auth.signOut();
          throw Exception(
            'This is an admin-panel account. Sign in through the admin panel instead.',
          );
        }
        await _refreshProfile(uid);
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
      final uid = supabase.auth.currentUser!.id;
      if (await _isStaffAccount(uid)) {
        await supabase.auth.signOut();
        throw Exception(
          'This is an admin-panel account. Sign in through the admin panel instead.',
        );
      }
      await _refreshProfile(uid);
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
      await _refreshProfile(res.session!.user.id);
      return true;
    }
    _awaitingOtpFinish = false;
    return false;
  });

  void finishAuth() {
    _awaitingOtpFinish = false;
    if (_user == null) return;
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
    super.dispose();
  }
}
