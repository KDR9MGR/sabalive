import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';
import '../config/supabase_config.dart';
import '../data/models.dart';

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
    // Session exists (sign-in, token refresh, restored on cold start, or —
    // importantly — the OAuth deep-link returning after Google/Apple).
    await _refreshProfile(session.user.id);
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

  Future<void> _refreshProfile(String userId) async {
    final row = await supabase.from('profiles').select().eq('id', userId).maybeSingle();
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

  Future<void> loginWithPassword(String id, String password) => _guard(() async {
        final trimmed = id.trim();
        if (trimmed.contains('@')) {
          await supabase.auth.signInWithPassword(email: trimmed, password: password);
        } else {
          await supabase.auth.signInWithPassword(phone: trimmed, password: password);
        }
        final uid = supabase.auth.currentUser!.id;
        await _refreshProfile(uid);
        _status = AuthStatus.authenticated;
        notifyListeners();
      });

  Future<void> loginWithSocial(String provider) => _guard(() async {
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
        final res = await supabase.auth.verifyOTP(phone: phone, token: code, type: OtpType.sms);
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
  }) =>
      _guard(() async {
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

  Future<void> updateProfile({
    String? name,
    String? username,
    String? bio,
    String? location,
  }) =>
      _guard(() async {
        final uid = supabase.auth.currentUser;
        if (uid == null) return;
        final updates = <String, dynamic>{
          'name': ?name,
          'username': ?username?.replaceFirst('@', ''),
          'bio': ?bio,
          'location': ?location,
        };
        if (updates.isEmpty) return;
        await supabase.from('profiles').update(updates).eq('id', uid.id);
        await _refreshProfile(uid.id);
      });

  Future<void> signOut() => _guard(() async {
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
        await supabase.rpc('request_account_deletion', params: {'p_reason': reason});
        await supabase.auth.signOut();
        _user = null;
        _status = AuthStatus.unauthenticated;
        notifyListeners();
      });

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}
