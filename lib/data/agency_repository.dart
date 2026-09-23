import '../config/supabase_client.dart';

/// One user's own agency application/membership — null fields mean "not
/// applied yet". `agencies.status` starts 'pending' and an admin flips it
/// to 'active' (approved) or 'inactive' (rejected/disabled).
class AgencyStatus {
  AgencyStatus({required this.name, required this.status, required this.holderName});

  factory AgencyStatus.fromRow(Map<String, dynamic> row) => AgencyStatus(
        name: row['name'] as String,
        status: row['status'] as String,
        holderName: row['holder_name'] as String?,
      );

  final String name;
  final String status; // pending | active | inactive
  final String? holderName;
}

/// Self-serve "Apply for Agency" — `apply_for_agency` RPC (SECURITY
/// DEFINER, since agencies' own INSERT policy is admin-only), and reading
/// back your own application via the existing "...or their own manager"
/// SELECT policy on `agencies` — no new read path needed.
class AgencyRepository {
  String? get _me => supabase.auth.currentUser?.id;

  Future<AgencyStatus?> myApplication() async {
    final me = _me;
    if (me == null) return null;
    final row = await supabase
        .from('agencies')
        .select('name, status, holder_name')
        .eq('manager_id', me)
        .maybeSingle();
    return row == null ? null : AgencyStatus.fromRow(row);
  }

  Future<void> apply({
    required String name,
    required String holderName,
    required String whatsapp,
    required String country,
    String? reference,
  }) async {
    await supabase.rpc('apply_for_agency', params: {
      'p_name': name,
      'p_holder_name': holderName,
      'p_whatsapp': whatsapp,
      'p_country': country,
      'p_reference': reference,
    });
  }
}
