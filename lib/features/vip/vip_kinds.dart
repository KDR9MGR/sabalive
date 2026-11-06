import 'package:flutter/material.dart';

/// The kinds of benefit a VIP product can list (owner, 2026-11-06). The panel offers the same list (`sabaliveadmin/src/lib/vipProducts.js`, `VIP_KINDS`): keep the two in step.
/// A product stores only the KEY (`vip_product_benefits.kind`), so a new kind needs no database change; an unknown key still shows, with its own title and a star.
///
/// [gives] is true for a kind that really DOES something when it is linked to a Store item (the buyer is given that item for the VIP's days): the frame, entry effect, vehicle and
/// room theme. `identity` is the product's badge on the person's own profile. Everything else is only LISTED for now: its rule (Anti-Kick, Anti-Ban, Hide Country, XP boost,
/// Daily Check In ...) is switched on one at a time when the owner decides it.
@immutable
class VipKind {
  const VipKind(this.key, this.label, this.icon, {this.gives = false});

  final String key;

  /// English; the screen translates it.
  final String label;
  final IconData icon;
  final bool gives;
}

const String kVipCustomKind = 'custom';

const List<VipKind> kVipKinds = [
  VipKind('identity', 'Identity', Icons.verified_rounded, gives: true),
  VipKind('entry_effect', 'Entry Effect', Icons.auto_awesome_rounded, gives: true),
  VipKind('vehicle', 'Vehicle', Icons.directions_car_filled_rounded, gives: true),
  VipKind('avatar_frame', 'Avatar Frame', Icons.portrait_rounded, gives: true),
  VipKind('join_entry_effect', 'Join Entry Effect', Icons.login_rounded),
  VipKind('comment_box', 'Comment Box', Icons.chat_bubble_outline_rounded),
  VipKind('special_gift', 'Special Gift', Icons.card_giftcard_rounded),
  VipKind('theme', 'Theme', Icons.palette_outlined, gives: true),
  VipKind('hide_country', 'Hide Country', Icons.public_off_rounded),
  VipKind('short_profile_decoration', 'Short Profile Decoration', Icons.wallpaper_rounded),
  VipKind('special_global_gift_effect', 'Special Global Gift Effect', Icons.celebration_rounded),
  VipKind('colourful_user_name', 'Colourful User Name', Icons.text_fields_rounded),
  VipKind('video_call_frame', 'Video Call Frame', Icons.videocam_outlined),
  VipKind('high_speed_upgrade', 'High Speed Upgrade', Icons.rocket_launch_outlined),
  VipKind('higher_rank', 'Higher Rank', Icons.leaderboard_rounded),
  VipKind('daily_check_in', 'Daily Check In', Icons.event_available_rounded),
  VipKind('guardian', 'Guardian', Icons.shield_outlined),
  VipKind('anti_kick', 'Anti-Kick', Icons.do_not_disturb_on_outlined),
  VipKind('anti_ban', 'Anti-Ban', Icons.gpp_good_outlined),
];

/// The kind for [key]; a key this app does not know (a newer panel) or `custom` gives a plain star, and the benefit's own title is what is shown.
VipKind vipKindFor(String key) {
  for (final k in kVipKinds) {
    if (k.key == key) return k;
  }
  return VipKind(key, '', Icons.star_rounded);
}
