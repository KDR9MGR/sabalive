import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';
import '../services/device_identity_service.dart';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// `09 Oct 2026` — how a ban's end date is shown to the user.
String formatBanDate(DateTime d) {
  final local = d.toLocal();
  return '${local.day.toString().padLeft(2, '0')} ${_months[local.month - 1]} ${local.year}';
}

/// One kind of restriction on this user / device: until a date, or forever.
class BanInfo {
  const BanInfo({this.until, this.permanent = false});

  factory BanInfo.fromJson(Map<dynamic, dynamic> json) {
    final until = json['until'] as String?;
    return BanInfo(
      until: until == null ? null : DateTime.parse(until).toUtc(),
      permanent: json['permanent'] == true,
    );
  }

  final DateTime? until;
  final bool permanent;

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
  /// The signed-in user's restrictions (`my_restrictions`).
  Future<Restrictions> mine() async {
    final res = await supabase.rpc('my_restrictions');
    return Restrictions.fromJson(res);
  }

  static BanInfo? _bannedOrNull(Object? res) {
    if (res is Map && res['banned'] == true) return BanInfo.fromJson(res);
    return null;
  }

  /// Is this phone banned? Callable before sign-in.
  Future<BanInfo?> checkDevice(String deviceId) async {
    final res = await supabase.rpc(
      'check_device_access',
      params: {'p_device_id': deviceId},
    );
    return _bannedOrNull(res);
  }

  /// Tells the server this account uses this device, and whether it is banned.
  Future<BanInfo?> registerDevice(DeviceIdentity device) async {
    final res = await supabase.rpc(
      'register_device',
      params: {
        'p_device_id': device.id,
        'p_platform': device.platform,
        'p_model': device.model,
      },
    );
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
