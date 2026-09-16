import 'package:flutter/material.dart';

import '../core/utils/errors.dart';
import '../data/messages_repository.dart';
import '../data/models.dart';
import '../data/social_repository.dart';
import '../features/common/access_code_screen.dart';
import '../features/games/games_screen.dart';
import '../features/host/host_dashboard_screen.dart';
import '../features/live/go_live_setup_screen.dart';
import '../features/live/watch_live_screen.dart';
import '../features/messages/chat_screen.dart';
import '../features/messages/new_group_screen.dart';
import '../features/profile/edit_profile_screen.dart';
import '../features/profile/follow_list_screen.dart';
import '../features/profile/kyc_screen.dart';
import '../features/profile/notifications_screen.dart';
import '../features/profile/settings_screen.dart';
import '../features/profile/user_profile_screen.dart';
import '../features/search/search_screen.dart';
import '../features/wallet/buy_coins_screen.dart';
import '../features/wallet/sell_coins_screen.dart';
import '../features/wallet/wallet_screen.dart';

/// Thin wrapper so feature screens don't each import MaterialPageRoute plumbing.
class AppNav {
  AppNav._();

  static Future<T?> _push<T>(BuildContext context, Widget page) {
    return Navigator.of(context).push<T>(
      MaterialPageRoute(builder: (_) => page),
    );
  }

  static Future<void> watchLive(BuildContext context, LiveStream stream) =>
      _push(context, WatchLiveScreen(stream: stream));

  /// Routes through the host-code gate; only lands on go-live setup once the
  /// user has (or unlocks) agency host access.
  static Future<void> goLive(BuildContext context) {
    final repo = SocialRepository();
    return _push(
      context,
      AccessCodeScreen(
        title: 'Host Access',
        blurb: 'Going live is enabled by your agency. Paste the host code they '
            'gave you to unlock it.',
        check: repo.hostAccess,
        redeem: repo.redeemHostCode,
        destination: (_) => const GoLiveSetupScreen(),
      ),
    );
  }

  /// Coin selling / reseller tool — behind an agency-issued reseller code.
  static Future<void> sellCoins(BuildContext context) {
    final repo = SocialRepository();
    return _push(
      context,
      AccessCodeScreen(
        title: 'Coin Reseller Access',
        blurb: 'Selling coins is enabled by your agency or the admin team. '
            'Enter your reseller code to unlock it.',
        check: repo.resellerAccess,
        redeem: repo.redeemResellerCode,
        destination: (_) => const SellCoinsScreen(),
      ),
    );
  }

  static Future<void> chat(
    BuildContext context,
    AppUser user, {
    required String conversationId,
  }) =>
      _push(context, ChatScreen(user: user, conversationId: conversationId));

  /// Opens (creating if needed) the 1:1 conversation with [user], then the
  /// chat screen. Shows a snackbar if the conversation can't be started.
  static Future<void> chatWith(BuildContext context, AppUser user) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final id = await MessagesRepository().findOrCreateConversation(user);
      await navigator.push(MaterialPageRoute(
        builder: (_) => ChatScreen(user: user, conversationId: id),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  static Future<void> userProfile(BuildContext context, AppUser user) =>
      _push(context, UserProfileScreen(user: user));

  static Future<void> followList(
    BuildContext context,
    String userId, {
    required bool followers,
  }) =>
      _push(context, FollowListScreen(userId: userId, followers: followers));

  static Future<void> kyc(BuildContext context) =>
      _push(context, const KycScreen());

  /// Finds [host]'s current live stream and opens the watch screen.
  static Future<void> watchHostLive(BuildContext context, AppUser host) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final stream = await SocialRepository().liveStreamForHost(host.id);
    if (stream == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('This host is not live right now')),
      );
      return;
    }
    await navigator.push(
      MaterialPageRoute(builder: (_) => WatchLiveScreen(stream: stream)),
    );
  }

  static Future<void> search(BuildContext context) =>
      _push(context, const SearchScreen());

  static Future<void> games(BuildContext context) =>
      _push(context, const GamesScreen());

  static Future<void> newGroup(BuildContext context) =>
      _push(context, const NewGroupScreen());

  static Future<void> hostDashboard(BuildContext context) =>
      _push(context, const HostDashboardScreen());

  static Future<void> wallet(BuildContext context) =>
      _push(context, const WalletScreen());

  static Future<void> buyCoins(BuildContext context) =>
      _push(context, const BuyCoinsScreen());

  static Future<void> notifications(BuildContext context) =>
      _push(context, const NotificationsScreen());

  static Future<void> settings(BuildContext context) =>
      _push(context, const SettingsScreen());

  static Future<void> editProfile(BuildContext context) =>
      _push(context, const EditProfileScreen());
}
