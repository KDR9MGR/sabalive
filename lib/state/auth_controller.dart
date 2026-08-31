import 'package:flutter/foundation.dart';

import '../data/mock_data.dart';
import '../data/models.dart';

enum AuthStatus { unknown, onboarding, unauthenticated, authenticated }

/// Fake auth service. Simulates network latency and OTP verification entirely
/// in memory — no real backend. Any 6-digit code is accepted.
class AuthController extends ChangeNotifier {
  AuthStatus _status = AuthStatus.unknown;
  AppUser? _user;
  bool _busy = false;
  String? _pendingPhone;

  AuthStatus get status => _status;
  AppUser? get user => _user;
  bool get busy => _busy;
  String get pendingPhone => _pendingPhone ?? '+91 98765 43210';

  Future<void> _simulate([int ms = 900]) async {
    _busy = true;
    notifyListeners();
    await Future<void>.delayed(Duration(milliseconds: ms));
    _busy = false;
  }

  void completeSplash() {
    if (_status == AuthStatus.unknown) {
      _status = AuthStatus.onboarding;
      notifyListeners();
    }
  }

  void completeOnboarding() {
    _status = AuthStatus.unauthenticated;
    notifyListeners();
  }

  Future<void> loginWithPassword(String id, String password) async {
    await _simulate();
    _user = Mock.me;
    _status = AuthStatus.authenticated;
    notifyListeners();
  }

  Future<void> loginWithSocial(String provider) async {
    await _simulate(700);
    _user = Mock.me;
    _status = AuthStatus.authenticated;
    notifyListeners();
  }

  /// Step 1 of phone / sign-up flow — "sends" an OTP.
  Future<void> requestOtp(String phone) async {
    _pendingPhone = phone;
    await _simulate(700);
    notifyListeners();
  }

  /// Step 2 — verifies. Accepts any 6-digit string. Does not sign the user in
  /// yet so the success screen can be shown; call [finishAuth] to continue.
  Future<bool> verifyOtp(String code) async {
    await _simulate(800);
    return code.length == 6;
  }

  void finishAuth() {
    _user ??= Mock.me;
    _status = AuthStatus.authenticated;
    notifyListeners();
  }

  Future<void> signUp({
    required String name,
    required String email,
    required String username,
  }) async {
    await _simulate();
    _user = AppUser(
      id: 'me',
      name: name.isEmpty ? 'New Star' : name,
      username: username.isEmpty ? '@newstar' : '@$username',
      bio: 'New on SABALIVE ✨',
      level: 1,
    );
    _status = AuthStatus.authenticated;
    notifyListeners();
  }

  Future<void> resetPassword(String target) async {
    await _simulate(700);
    notifyListeners();
  }

  void updateProfile({
    String? name,
    String? username,
    String? bio,
    String? location,
  }) {
    final u = _user;
    if (u == null) return;
    if (name != null) u.name = name;
    if (username != null) u.username = username;
    if (bio != null) u.bio = bio;
    if (location != null) u.location = location;
    notifyListeners();
  }

  void signOut() {
    _user = null;
    _status = AuthStatus.unauthenticated;
    notifyListeners();
  }
}
