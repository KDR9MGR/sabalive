import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';
import '../data/social_repository.dart';

/// Follows (real, backed by the `follows` table), liked streams (local for
/// now — no per-user likes table), and the selected bottom-nav tab.
class SessionController extends ChangeNotifier {
  SessionController() {
    _authSub = supabase.auth.onAuthStateChange.listen((state) {
      final uid = state.session?.user.id;
      if (uid == null) {
        _following.clear();
        _likedStreams.clear();
        notifyListeners();
      } else {
        _loadFollowing();
        _loadLikes();
      }
    });
    if (supabase.auth.currentUser != null) {
      _loadFollowing();
      _loadLikes();
    }
  }

  final _repo = SocialRepository();
  final Set<String> _following = {};
  final Set<String> _likedStreams = {};
  int _tab = 0;
  StreamSubscription<AuthState>? _authSub;

  int get tab => _tab;
  set tab(int value) {
    if (value == _tab) return;
    _tab = value;
    notifyListeners();
  }

  Future<void> _loadFollowing() async {
    try {
      final ids = await _repo.myFollowingIds();
      _following
        ..clear()
        ..addAll(ids);
      notifyListeners();
    } catch (_) {/* stay with whatever we have */}
  }

  bool isFollowing(String userId) => _following.contains(userId);

  /// Optimistic — flips locally, then persists; reverts on failure.
  Future<void> toggleFollow(String userId) async {
    final wasFollowing = _following.contains(userId);
    if (wasFollowing) {
      _following.remove(userId);
    } else {
      _following.add(userId);
    }
    notifyListeners();
    try {
      if (wasFollowing) {
        await _repo.unfollow(userId);
      } else {
        await _repo.follow(userId);
      }
    } catch (_) {
      if (wasFollowing) {
        _following.add(userId);
      } else {
        _following.remove(userId);
      }
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _loadLikes() async {
    try {
      final ids = await _repo.likedStreamIds();
      _likedStreams
        ..clear()
        ..addAll(ids);
      notifyListeners();
    } catch (_) {}
  }

  bool isLiked(String streamId) => _likedStreams.contains(streamId);

  Future<void> toggleLike(String streamId) async {
    final wasLiked = _likedStreams.contains(streamId);
    if (wasLiked) {
      _likedStreams.remove(streamId);
    } else {
      _likedStreams.add(streamId);
    }
    notifyListeners();
    try {
      if (wasLiked) {
        await _repo.unlikeStream(streamId);
      } else {
        await _repo.likeStream(streamId);
      }
    } catch (_) {
      if (wasLiked) {
        _likedStreams.add(streamId);
      } else {
        _likedStreams.remove(streamId);
      }
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}
