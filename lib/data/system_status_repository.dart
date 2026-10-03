import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';

/// What the Super Admin has set for maintenance, as the server sees it right now
/// (`get_system_status`).
class SystemStatus {
  const SystemStatus({
    required this.status,
    required this.title,
    required this.message,
    required this.serverTime,
    this.imageUrl,
    this.startsAt,
    this.endsAt,
    this.autoEnd = false,
    this.lockApp = true,
    this.blockLogins = true,
    this.lockPanel = false,
    this.appSessionVersion = 1,
  });

  /// `online`, `upcoming` (scheduled, not started), `maintenance` or `lockdown`.
  final String status;
  final String title;
  final String message;
  final String? imageUrl;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final bool autoEnd;
  final bool lockApp;
  final bool blockLogins;
  final bool lockPanel;

  /// Moves whenever the Super Admin logs every app user out.
  final int appSessionVersion;

  /// The server's clock when this was read. The countdown runs from it, never
  /// from the phone's own (possibly wrong) clock.
  final DateTime serverTime;

  factory SystemStatus.fromJson(Map<dynamic, dynamic> json) {
    DateTime? time(String key) {
      final v = json[key];
      return v is String ? DateTime.tryParse(v)?.toUtc() : null;
    }

    return SystemStatus(
      status: json['status'] as String? ?? 'online',
      title: json['title'] as String? ?? "We'll be right back",
      message: json['message'] as String? ?? '',
      imageUrl: (json['image_url'] as String?)?.trim().isEmpty ?? true
          ? null
          : (json['image_url'] as String).trim(),
      startsAt: time('starts_at'),
      endsAt: time('ends_at'),
      autoEnd: json['auto_end'] == true,
      lockApp: json['lock_app'] != false,
      blockLogins: json['block_logins'] != false,
      lockPanel: json['lock_panel'] == true,
      appSessionVersion: (json['app_session_version'] as num?)?.toInt() ?? 1,
      serverTime: time('server_time') ?? DateTime.now().toUtc(),
    );
  }

  /// What a request refused by the server gate (HTTP 503 MAINTENANCE_MODE) says.
  /// [details] is the JSON the gate attaches: status, title, message, ends_at.
  factory SystemStatus.fromGateDetails(Map<dynamic, dynamic> details) =>
      SystemStatus.fromJson({
        ...details,
        'lock_app': true,
        'block_logins': true,
      });

  /// Nothing set: the app is open.
  static final online = SystemStatus(
    status: 'online',
    title: '',
    message: '',
    serverTime: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );

  bool get isLockdown => status == 'lockdown';

  /// The whole app is closed: the maintenance screen covers everything.
  bool get locksApp => isLockdown || (status == 'maintenance' && lockApp);

  /// Signing in and signing up are closed (even if the rest of the app is open).
  bool get blocksLogins =>
      locksApp || (status == 'maintenance' && blockLogins);

  /// Maintenance is coming or running but the app stays usable: show a notice.
  bool get showsNotice =>
      !locksApp && (status == 'upcoming' || status == 'maintenance');
}

class SystemStatusRepository {
  Future<SystemStatus> fetch() async {
    final res = await supabase.rpc('get_system_status');
    if (res is! Map) return SystemStatus.online;
    return SystemStatus.fromJson(res);
  }

  /// Calls [onChange] whenever the Super Admin changes the state, so a lockout
  /// or a lifted lockout reaches the app within a moment.
  RealtimeChannel watch(void Function() onChange) {
    return supabase
        .channel('system-state')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'system_state',
          callback: (_) => onChange(),
        )
        .subscribe();
  }
}
