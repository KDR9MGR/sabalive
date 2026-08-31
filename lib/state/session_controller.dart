import 'package:flutter/foundation.dart';

/// Lightweight per-session UI state: who you follow, which streams you've liked,
/// and the selected bottom-nav tab. Purely in-memory.
class SessionController extends ChangeNotifier {
  final Set<String> _following = {'nisha', 'arjun'};
  final Set<String> _likedStreams = {};
  int _tab = 0;

  int get tab => _tab;
  set tab(int value) {
    if (value == _tab) return;
    _tab = value;
    notifyListeners();
  }

  bool isFollowing(String userId) => _following.contains(userId);

  void toggleFollow(String userId) {
    if (!_following.remove(userId)) _following.add(userId);
    notifyListeners();
  }

  bool isLiked(String streamId) => _likedStreams.contains(streamId);

  void toggleLike(String streamId) {
    if (!_likedStreams.remove(streamId)) _likedStreams.add(streamId);
    notifyListeners();
  }
}
