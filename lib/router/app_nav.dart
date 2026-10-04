import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/utils/errors.dart';
import '../core/widgets/over_live_route.dart';
import '../data/messages_repository.dart';
import '../data/models.dart';
import '../data/social_repository.dart';
import '../features/common/agency_request_screen.dart';
import '../features/games/games_screen.dart';
import '../features/host/host_dashboard_screen.dart';
import '../features/live/go_live_setup_screen.dart';
import '../features/live/watch_audio_room_screen.dart';
import '../features/live/watch_live_screen.dart';
import '../features/live/watch_pk_battle_screen.dart';
import '../features/live/live_access_exit.dart';
import '../state/active_live_session_controller.dart';
import '../state/auth_controller.dart';
import '../theme/app_colors.dart';
import '../features/messages/chat_screen.dart';
import '../features/messages/new_group_screen.dart';
import '../features/profile/apply_agency_screen.dart';
import '../features/profile/badges_screen.dart';
import '../features/profile/edit_profile_screen.dart';
import '../features/profile/feedback_screen.dart';
import '../features/profile/follow_list_screen.dart';
import '../features/profile/kyc_screen.dart';
import '../features/profile/my_level_screen.dart';
import '../features/profile/notifications_screen.dart';
import '../features/profile/profile_visitors_screen.dart';
import '../features/profile/referrals_screen.dart';
import '../features/profile/settings_screen.dart';
import '../features/profile/support_chat_screen.dart';
import '../features/profile/user_profile_screen.dart';
import '../features/search/search_screen.dart';
import '../features/wallet/bag_screen.dart';
import '../features/wallet/frames_screen.dart';
import '../features/wallet/buy_coins_screen.dart';
import '../features/wallet/coin_sellers_screen.dart';
import '../features/wallet/sell_coins_screen.dart';
import '../features/wallet/store_screen.dart';
import '../features/wallet/wallet_screen.dart';

/// Thin wrapper so feature screens don't each import MaterialPageRoute plumbing.
class AppNav {
  AppNav._();

  static Future<T?> _push<T>(BuildContext context, Widget page) {
    return Navigator.of(context).push<T>(route<T>(context, page));
  }

  /// How a page opens: a normal full-screen page, or — while a live is on
  /// screen — a sheet over the room, so the live keeps running behind it
  /// instead of being replaced.
  static Route<T> route<T>(BuildContext context, Widget page) {
    final live = context.read<ActiveLiveSessionController>();
    if (live.isActive && !live.isMinimized) return OverLiveRoute<T>(page);
    return MaterialPageRoute<T>(builder: (_) => page);
  }

  /// Opens [page] the app's way (see [route]) — for screens that used to push a
  /// MaterialPageRoute directly.
  static Future<T?> open<T>(BuildContext context, Widget page) =>
      _push<T>(context, page);

  /// True when the caller should NOT proceed — either a DIFFERENT live is
  /// already active (shows "Return to Live" / "Cancel", per spec) or this
  /// exact room is already the active session (just restores it instead of
  /// starting a second connection to the same room). The app only ever
  /// runs one Agora engine at a time, so a second concurrent session would
  /// break the first rather than running both.
  static Future<bool> _blockedByActiveSession(
    BuildContext context,
    String? requestedRoomId,
  ) async {
    final session = context.read<ActiveLiveSessionController>();
    if (!session.isActive) return false;
    if (requestedRoomId != null && session.roomId == requestedRoomId) {
      session.restore();
      return true;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('Already in a live'),
        content: Text(
          "You're still live in ${session.hostName}'s room — finish or "
          'return to it before starting or joining another one.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'return'),
            child: const Text('Return to Live'),
          ),
        ],
      ),
    );
    if (choice == 'return') session.restore();
    return true;
  }

  /// True (after saying why) when the user is banned from live — an ID, device
  /// or live ban. The database refuses the join anyway; this just spares them a
  /// room that would throw them straight back out.
  static Future<bool> _blockedByLiveBan(BuildContext context) async {
    final message = context
        .read<AuthController>()
        .restrictions
        .liveBlockMessage();
    if (message == null) return false;
    await showLiveBlockedDialog(context, message);
    return true;
  }

  /// Video/audio watch screens register with the global
  /// ActiveLiveSessionController instead of being pushed — the root
  /// overlay in app.dart (see that file) mounts them above every route,
  /// which is what lets minimizing keep the whole app genuinely
  /// interactive underneath, not just whatever screen happened to be on
  /// top of this Navigator at the time. PK has no minimize option (it's
  /// naturally self-blocking — no way to background it and reach another
  /// live without ending it first), so it keeps the normal opaque route
  /// and never touches the session controller.
  static Future<void> watchLive(BuildContext context, LiveStream stream) async {
    if (await _blockedByLiveBan(context)) return;
    if (!context.mounted) return;
    if (await _blockedByActiveSession(context, stream.id)) return;
    if (!context.mounted) return;
    if (stream.mode == LiveMode.pk) {
      await _push(context, WatchPkBattleScreen(stream: stream));
      return;
    }
    context.read<ActiveLiveSessionController>().start(
      roomId: stream.id,
      hostName: stream.host.name,
      hostAvatarUrl: stream.host.avatarUrl,
      builder: (_) => switch (stream.mode) {
        LiveMode.video => WatchLiveScreen(stream: stream),
        LiveMode.audio => WatchAudioRoomScreen(stream: stream),
        LiveMode.pk => WatchPkBattleScreen(stream: stream),
      },
    );
  }

  /// Routes through the agency-request gate; only lands on go-live setup once
  /// the user has host access — i.e. an agency approved their request (they
  /// enter that agency's ID; the agency sees it in the admin panel). No host
  /// code any more. There's no roomId yet at
  /// this point (the stream doesn't exist until go_live_setup_screen.dart's
  /// own _start() creates it) — blocked purely on "is ANY session already
  /// active", same as trying to watch while already live.
  static Future<void> goLive(BuildContext context) async {
    if (await _blockedByLiveBan(context)) return;
    if (!context.mounted) return;
    if (await _blockedByActiveSession(context, null)) return;
    if (!context.mounted) return;
    final repo = SocialRepository();
    return _push(
      context,
      AgencyRequestScreen(
        repo: repo,
        destination: (_) => const GoLiveSetupScreen(),
      ),
    );
  }

  /// Coin selling / reseller tool — open to any signed-in user, no access
  /// code required.
  static Future<void> sellCoins(BuildContext context) =>
      _push(context, const SellCoinsScreen());

  static Future<void> chat(
    BuildContext context,
    AppUser user, {
    required String conversationId,
  }) => _push(context, ChatScreen(user: user, conversationId: conversationId));

  /// Opens (creating if needed) the 1:1 conversation with [user], then the
  /// chat screen. Shows a snackbar if the conversation can't be started.
  static Future<void> chatWith(BuildContext context, AppUser user) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final id = await MessagesRepository().findOrCreateConversation(user);
      await navigator.push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(user: user, conversationId: id),
        ),
      );
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
  }) => _push(context, FollowListScreen(userId: userId, followers: followers));

  static Future<void> kyc(BuildContext context) =>
      _push(context, const KycScreen());

  /// Finds [host]'s current live stream and opens the watch screen, routed
  /// by the stream's actual mode (video/audio/pk) — same as [watchLive].
  static Future<void> watchHostLive(BuildContext context, AppUser host) async {
    final messenger = ScaffoldMessenger.of(context);
    final stream = await SocialRepository().liveStreamForHost(host.id);
    if (stream == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('This host is not live right now')),
      );
      return;
    }
    if (!context.mounted) return;
    await watchLive(context, stream);
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

  static Future<void> coinSellers(BuildContext context) =>
      _push(context, const CoinSellersScreen());

  static Future<void> notifications(BuildContext context) =>
      _push(context, const NotificationsScreen());

  static Future<void> settings(BuildContext context) =>
      _push(context, const SettingsScreen());

  static Future<void> editProfile(BuildContext context) =>
      _push(context, const EditProfileScreen());

  static Future<void> feedback(BuildContext context) =>
      _push(context, const FeedbackScreen());

  static Future<void> supportChat(BuildContext context) =>
      _push(context, const SupportChatScreen());

  static Future<void> applyAgency(BuildContext context) =>
      _push(context, const ApplyAgencyScreen());

  static Future<void> profileVisitors(BuildContext context) =>
      _push(context, const ProfileVisitorsScreen());

  static Future<void> referrals(BuildContext context) =>
      _push(context, const ReferralsScreen());

  static Future<void> myLevel(BuildContext context) =>
      _push(context, const MyLevelScreen());

  static Future<void> badges(BuildContext context, String profileId) =>
      _push(context, BadgesScreen(profileId: profileId));

  static Future<void> store(BuildContext context) =>
      _push(context, const StoreScreen());

  static Future<void> frames(BuildContext context) =>
      _push(context, const FramesScreen());

  static Future<void> bag(BuildContext context) =>
      _push(context, const BagScreen());
}
