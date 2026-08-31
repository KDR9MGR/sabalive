import 'package:flutter/material.dart';

import '../data/models.dart';
import '../features/live/go_live_setup_screen.dart';
import '../features/live/watch_live_screen.dart';
import '../features/messages/chat_screen.dart';
import '../features/profile/edit_profile_screen.dart';
import '../features/profile/notifications_screen.dart';
import '../features/profile/settings_screen.dart';
import '../features/wallet/buy_coins_screen.dart';
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

  static Future<void> goLive(BuildContext context) =>
      _push(context, const GoLiveSetupScreen());

  static Future<void> chat(BuildContext context, AppUser user) =>
      _push(context, ChatScreen(user: user));

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
