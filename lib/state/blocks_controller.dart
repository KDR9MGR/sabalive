import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config/supabase_client.dart';
import '../data/social_repository.dart';

/// The people the signed-in user has blocked, kept in memory so every screen can
/// hide them without a round trip: live chat, the live feed, the inbox.
///
/// A block is also enforced by the database (a blocked user can't message you
/// or join your live); this is what makes your own screens stop showing them.
class BlocksController extends ChangeNotifier {
  BlocksController._(this._load, {bool bindToAuth = true}) {
    if (bindToAuth) _bindToAuth();
  }

  void _bindToAuth() {
    try {
      _authSub = supabase.auth.onAuthStateChange.listen((state) {
        if (state.session == null) {
          _clear();
        } else {
          unawaited(refresh());
        }
      });
      if (supabase.auth.currentSession != null) unawaited(refresh());
    } catch (_) {
      // Supabase isn't initialised (a widget test): nobody is blocked.
    }
  }

  /// One shared instance, created the first time something reads it (after
  /// Supabase is initialised).
  static final BlocksController instance = BlocksController._(
    () => SocialRepository().blockedIds(),
  );

  @visibleForTesting
  BlocksController.test(Future<Set<String>> Function() load)
    : this._(load, bindToAuth: false);

  final Future<Set<String>> Function() _load;
  StreamSubscription<dynamic>? _authSub;
  Set<String> _ids = const {};

  Set<String> get ids => _ids;

  bool isBlocked(String? userId) => userId != null && _ids.contains(userId);

  /// Drops [items] whose [userOf] is blocked.
  List<T> withoutBlocked<T>(Iterable<T> items, String? Function(T) userOf) => [
    for (final item in items)
      if (!isBlocked(userOf(item))) item,
  ];

  Future<void> refresh() async {
    try {
      final next = await _load();
      if (!setEquals(next, _ids)) {
        _ids = next;
        notifyListeners();
      }
    } catch (_) {
      // keep what we have; a failed read mustn't un-hide anyone
    }
  }

  /// Call after a block / unblock has been saved.
  void markBlocked(String userId) {
    if (_ids.contains(userId)) return;
    _ids = {..._ids, userId};
    notifyListeners();
  }

  void markUnblocked(String userId) {
    if (!_ids.contains(userId)) return;
    _ids = {..._ids}..remove(userId);
    notifyListeners();
  }

  void _clear() {
    if (_ids.isEmpty) return;
    _ids = const {};
    notifyListeners();
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}
