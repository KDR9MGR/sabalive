import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';
import '../services/device_identity_service.dart';

/// One signed-in device per account. The device that signs in last takes the
/// session (`claim_session`); the database signs the earlier one out and tells it
/// over Realtime, so it leaves at once instead of at its next token refresh.
class SessionRepository {
  /// Records this sign-in (how, and from which device) and ends every other
  /// session of the account.
  Future<void> claim({
    required String method,
    required DeviceIdentity device,
  }) async {
    await supabase.rpc(
      'claim_session',
      params: {
        'p_method': method,
        'p_device_id': device.id,
        'p_platform': device.platform,
        'p_model': device.model,
      },
    );
  }

  /// Calls [onChange] with the new row whenever the account's active session
  /// changes — i.e. whenever any device signs in.
  RealtimeChannel watch(
    String userId,
    void Function(Map<String, dynamic> row) onChange,
  ) {
    return supabase
        .channel('my-session:$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'user_active_session',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) => onChange(payload.newRecord),
        )
        .subscribe();
  }
}
