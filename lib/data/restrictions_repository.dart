import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';
import '../services/device_identity_service.dart';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// `09 Oct 2026, 14:30` (the phone's own time) — how a ban's end is shown to the user. The time matters: a 24 hour ban ends at a time of day.
String formatBanDate(DateTime d) {
  final local = d.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '${local.day.toString().padLeft(2, '0')} ${_months[local.month - 1]} ${local.year}, $hh:$mm';
}

/// One kind of restriction on this user / device: until a date, or forever.
class BanInfo {
  const BanInfo({this.until, this.permanent = false, this.reason, this.note});

  factory BanInfo.fromJson(Map<dynamic, dynamic> json) {
    final until = json['until'] as String?;
    final note = json['note'];
    return BanInfo(
      until: until == null ? null : DateTime.parse(until).toUtc(),
      permanent: json['permanent'] == true,
      // `check_login_access_v2` calls the same thing `kind` (account / device / identity)
      reason: (json['reason'] ?? json['kind']) as String?,
      note: note is String && note.trim().isNotEmpty ? note.trim() : null,
    );
  }

  final DateTime? until;
  final bool permanent;

  /// Why a sign-up check refused: `device`, `identity` (a banned Google / email / phone) or `ip` (a short block on new
  /// accounts from a banned user's network). Null for the older answers that carried no reason.
  final String? reason;

  /// What the staff member who placed the ban wrote for the person (the panel's "Reason (shown to the user)"). Null when they wrote nothing, or the
  /// ban is an older one whose note was meant for staff only.
  final String? note;

  /// Still in force at [now]. A ban whose date has passed no longer counts even
  /// if the app hasn't heard from the server since.
  bool isActive([DateTime? now]) =>
      permanent || until == null || (now ?? DateTime.now()).isBefore(until!);

  /// "permanently" or "until 09 Oct 2026".
  String get phrase =>
      permanent || until == null ? 'permanently' : 'until ${formatBanDate(until!)}';
}

/// What the server says restricts this account and this device right now
/// (`my_restrictions`).
class Restrictions {
  const Restrictions({this.account, this.live, this.device});

  static const none = Restrictions();

  /// ID ban: the account can't be used at all.
  final BanInfo? account;

  /// Live ban: no watching, hosting, chatting, gifting or seats.
  final BanInfo? live;

  /// Device ban: this phone can't be used, whatever the account.
  final BanInfo? device;

  factory Restrictions.fromJson(Object? json) {
    if (json is! Map) return none;
    BanInfo? read(String key) {
      final v = json[key];
      return v is Map ? BanInfo.fromJson(v) : null;
    }

    return Restrictions(
      account: read('account'),
      live: read('live'),
      device: read('device'),
    );
  }

  /// Why the whole app is closed to this user, or null if it isn't.
  String? appBlockMessage([DateTime? now]) {
    final a = account;
    if (a != null && a.isActive(now)) return 'Your account is banned ${a.phrase}.';
    final d = device;
    if (d != null && d.isActive(now)) return 'This device is banned ${d.phrase}.';
    return null;
  }

  /// Why live is closed to this user (any ban counts), or null.
  String? liveBlockMessage([DateTime? now]) {
    final app = appBlockMessage(now);
    if (app != null) return app;
    final l = live;
    if (l != null && l.isActive(now)) return 'You are banned from live ${l.phrase}.';
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is Restrictions &&
      other.account?.until == account?.until &&
      other.account?.permanent == account?.permanent &&
      other.live?.until == live?.until &&
      other.live?.permanent == live?.permanent &&
      other.device?.until == device?.until &&
      other.device?.permanent == device?.permanent;

  @override
  int get hashCode => Object.hash(
    account?.until, account?.permanent,
    live?.until, live?.permanent,
    device?.until, device?.permanent,
  );
}

/// The app's side of the ban system. Bans themselves are placed from the admin
/// panel and enforced by the database; this only reads them so the app can show
/// the right message and step out of a room when one lands.
class RestrictionsRepository {
  RestrictionsRepository({@visibleForTesting Future<dynamic> Function(String function, Map<String, dynamic> params)? rpc})
      : _rpc = rpc ?? ((fn, params) => supabase.rpc(fn, params: params));

  final Future<dynamic> Function(String function, Map<String, dynamic> params) _rpc;

  /// The signed-in user's restrictions (`my_restrictions`).
  Future<Restrictions> mine() async {
    final res = await _rpc('my_restrictions', const {});
    return Restrictions.fromJson(res);
  }

  static BanInfo? _bannedOrNull(Object? res) {
    if (res is Map && res['banned'] == true) return BanInfo.fromJson(res);
    return null;
  }

  /// Before any sign-in / sign-up: is the account behind this email / phone number ID-banned, is this phone (any of its ids) banned, is this email /
  /// phone number on the blocklist — each with its end date and the reason staff wrote — and, for a NEW account only, is this network briefly
  /// blocked? Asks `check_login_access_v2` first; a database without it falls back to `check_signup_access`, and without that to the single-id check.
  Future<BanInfo?> checkSignup({
    required List<String> deviceIds,
    String? email,
    String? phone,
    bool newAccount = false,
  }) async {
    try {
      final res = await _rpc(
        'check_login_access_v2',
        {'p_device_ids': deviceIds, 'p_email': email, 'p_phone': phone},
      );
      final ban = _bannedOrNull(res);
      if (ban != null) return ban;
      // a sign-in has nothing more to ask; a new account is also checked against the short network block below
      if (!newAccount) return null;
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST202' && e.code != '42883') rethrow;
    }
    try {
      final res = await _rpc(
        'check_signup_access',
        {
          'p_device_ids': deviceIds,
          'p_email': email,
          'p_phone': phone,
          'p_new_account': newAccount,
        },
      );
      return _bannedOrNull(res);
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202' || e.code == '42883') {
        return deviceIds.isEmpty ? null : checkDevice(deviceIds.first);
      }
      rethrow;
    }
  }

  /// Is this phone banned? Callable before sign-in.
  Future<BanInfo?> checkDevice(String deviceId) async {
    final res = await _rpc('check_device_access', {'p_device_id': deviceId});
    return _bannedOrNull(res);
  }

  /// Tells the server this account uses this device, and whether it is banned.
  Future<BanInfo?> registerDevice(DeviceIdentity device) async {
    try {
      // v2 also records the hardware id and spreads a ban across every id this phone has shown
      final res = await _rpc('register_device_v2', {
        'p_device_id': device.id,
        'p_platform': device.platform,
        'p_model': device.model,
        'p_extra_ids': device.extraIds,
      });
      return _bannedOrNull(res);
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST202' && e.code != '42883') rethrow;
    }
    final res = await _rpc('register_device', {
      'p_device_id': device.id,
      'p_platform': device.platform,
      'p_model': device.model,
    });
    return _bannedOrNull(res);
  }

  /// Calls [onChange] whenever one of [userId]'s ban rows is added or changed,
  /// so a ban placed from the panel reaches the app at once.
  RealtimeChannel watchMine(String userId, void Function() onChange) {
    return supabase
        .channel('my-bans:$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'user_bans',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => onChange(),
        )
        .subscribe();
  }
}
