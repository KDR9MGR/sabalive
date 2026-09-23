import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';
import 'models.dart';

/// Self-serve feedback with admin triage — `feedback` table, RLS-scoped
/// (file as yourself, see only what you filed, admins triage). Mirrors
/// `SocialRepository.report()`'s shape: a plain client insert, no RPC
/// needed since RLS alone enforces who can write what.
class FeedbackRepository {
  String? get _me => supabase.auth.currentUser?.id;

  Future<void> submit({
    required FeedbackKind kind,
    required String body,
    String? contactMethod,
    String? contactValue,
  }) async {
    final me = _me;
    if (me == null) return;
    await supabase.from('feedback').insert({
      'profile_id': me,
      'kind': switch (kind) {
        FeedbackKind.appError => 'app_error',
        FeedbackKind.suggestion => 'suggestion',
        FeedbackKind.earningInfo => 'earning_info',
        FeedbackKind.other => 'other',
      },
      'body': body,
      'contact_method': contactMethod,
      'contact_value': contactValue,
    });
  }

  Future<List<FeedbackItem>> mine() async {
    final me = _me;
    if (me == null) return const [];
    final rows = await supabase
        .from('feedback')
        .select()
        .eq('profile_id', me)
        .order('created_at', ascending: false);
    return rows.map(FeedbackItem.fromRow).toList();
  }

  /// Live updates when an admin responds — same shape as WalletController's
  /// own-row Realtime subscription.
  RealtimeChannel subscribe(String profileId, void Function(FeedbackItem) onChange) {
    return supabase
        .channel('feedback-$profileId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'feedback',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'profile_id',
            value: profileId,
          ),
          callback: (payload) => onChange(FeedbackItem.fromRow(payload.newRecord)),
        )
        .subscribe();
  }
}
