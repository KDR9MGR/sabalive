import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../state/remote_config_controller.dart';

/// Switches for UI that's deliberately hidden during the alpha because the
/// backend behind it isn't real yet. Flip these to `true` — and remove this
/// comment's checklist item — as each backend piece actually lands:
///
/// - [socialLoginEnabled]: ON. Verified live against Supabase's `/authorize`
///   endpoint on 2026-09-15 — Google is configured (real redirect to
///   Google's consent screen); Apple and Facebook are not
///   (`"Unsupported provider: provider is not enabled"`). `SocialRow`
///   ([auth_scaffold.dart](lib/features/auth/widgets/auth_scaffold.dart))
///   shows only Google + Apple per product decision — Facebook stays out
///   until there's a reason to add it back. Tapping Apple right now opens
///   the browser to that raw Supabase error until its provider is
///   configured in the dashboard (Auth → Providers → Apple) and Apple
///   Developer's Services ID Return URL is set — see
///   `SupabaseConfig.authRedirectUrl`.
/// - [paymentMethodsEnabled]: needs a real payment gateway (Razorpay/Stripe/
///   IAP — not chosen yet). The UPI/Card/Net Banking/Wallet picker is fake
///   and stays hidden until a gateway is wired behind it. Buy Coins' Pay
///   button also checks this flag directly (2026-09-21, per Rey) — it used
///   to call `dev_purchase_coins` (a test RPC that instantly grants coins,
///   no real charge) regardless of this flag, so tapping Pay silently gave
///   free coins. Now shows "coming soon" instead while this is false.
/// - [pkBattleEnabled]: PK Battles are OFF unless the server says so (owner's
///   decision 2026-10-17: the next Play bundle ships with PK off, and audio PK is
///   switched on from the panel after it has been tested). It follows the
///   server switch `pk_battles` (Application Config -> Release controls, Super
///   Admin). While off, every place that would start or join a PK says "coming
///   soon", as it always did (2026-09-28, per Rey): Go Live's PK tab and the host
///   tools' Invite PK / Random PK tiles. [pkVideoEnabled] ('pk_video', also off
///   by default) is the separate switch for VIDEO PK, which stays off until its
///   Agora cost and reliability are measured; it only counts while PK is on.
///
/// - [callsEnabled]: voice/video calls between users are hidden everywhere
///   (the two call buttons in a chat, the incoming-call banner, and the
///   realtime listener for incoming calls — it is not even started while
///   this is false). Per product decision (2026-10-01) the app has no calling
///   for now. The calls code is left in place; flip this to bring it back.
///
/// ⚠️ Still on the pre-production checklist — wire the real thing behind it
/// before shipping to real users.
class FeatureFlags {
  FeatureFlags._();

  static const bool socialLoginEnabled = true;
  static const bool paymentMethodsEnabled = false;
  static bool get pkBattleEnabled => pkBattleEnabledFor(RemoteConfigController.instance);
  static bool get pkVideoEnabled => pkVideoEnabledFor(RemoteConfigController.instance);
  static bool get pkLayerEnabled => pkLayerEnabledFor(RemoteConfigController.instance);

  /// The rule behind [pkBattleEnabled], for any [RemoteConfigController] (tests use their own). Fails CLOSED: no answer from the
  /// server (no network, an old row) means off, like the Games switch.
  static bool pkBattleEnabledFor(RemoteConfigController config) => config.flag('pk_battles', defaultValue: false);

  /// The PK battle layer (PK inside a normal audio live) is the way PK works while PK is on. `pk_layer: false` is an emergency
  /// fallback to the old standalone PK screens (Go Live -> PK), without a release. It counts only while PK is on.
  static bool pkLayerEnabledFor(RemoteConfigController config) =>
      pkBattleEnabledFor(config) && config.flag('pk_layer', defaultValue: true);

  /// Video PK: needs the PK switch AND the battle layer on as well as its own (the old PK screens have no video).
  static bool pkVideoEnabledFor(RemoteConfigController config) =>
      pkLayerEnabledFor(config) && config.flag('pk_video', defaultValue: false);
  static const bool callsEnabled = false;

  /// For tests: pretend to be (true) or not to be (false) an iPhone. Null = the real platform.
  @visibleForTesting
  static bool? isIOSOverride;

  /// Is this an iPhone / iPad? (The App Store has rules the Play Store does not; see below.)
  static bool get isIOS => isIOSOverride ?? Platform.isIOS;

  /// App Store review (2026-10-27): Apple refuses a screen that only says "coming soon", so every entry that leads to one is HIDDEN on iOS (Room Effects, Family, Request Withdrawal,
  /// Funny voice, Invite someone, password reset by mobile number, the Games tab, Video PK). Android is unchanged. When one of them is really built, show it on iOS too by removing its check.
  static bool get comingSoonVisible => !isIOS;

  /// The Games tab and its entries. iOS has no games yet (the game panel is the Android WebView), so there it would only say "coming soon": hidden.
  static bool get gamesEntryVisible => !isIOS;

  /// "Buy Coins" and every "top up" prompt. The Buy Coins screen is not wired to a payment service (its Pay button says "coming soon"), and Apple requires In-App Purchase for coins
  /// sold in an iOS app (guideline 3.1.1), so on iOS there is no way to buy coins from the app until In-App Purchase is built.
  static bool get buyCoinsVisible => !isIOS;

  /// Invite PK / Random PK in a live's tools. On iOS only where they really work: PK is on in the panel, and the live is audio (video PK needs its own switch).
  static bool pkToolsVisible({required bool audioOnly}) => comingSoonVisible || (pkBattleEnabled && (audioOnly || pkVideoEnabled));

  /// The "Buy from Offline Seller" button (coin sellers). Always shown on Android. On iOS it follows the server switch `coin_seller_ios` (Application Config ->
  /// Release controls: "Coin sellers on iOS"). The default is OFF on iOS (2026-10-27): an offline seller is a way of buying coins outside In-App Purchase, which Apple does not allow, so an
  /// iPhone shows it only when someone turns the switch ON.
  static bool get coinSellerVisible => coinSellerVisibleFor(RemoteConfigController.instance, isIOS: isIOS);

  /// The rule behind [coinSellerVisible], for any [RemoteConfigController] and platform (tests use their own).
  static bool coinSellerVisibleFor(RemoteConfigController config, {required bool isIOS}) => !isIOS || config.flag('coin_seller_ios', defaultValue: false);
}
