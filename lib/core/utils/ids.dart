import 'dart:math';

final RegExp _uuidPattern =
    RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// True if [id] is a real Supabase row id (uuid) rather than one of the
/// app's hardcoded demo ids (e.g. 'nisha', 's1').
bool isRealId(String id) => _uuidPattern.hasMatch(id);

final _rng = Random.secure();

/// RFC 4122 v4 UUID — used for client-generated channel names etc.
String newUuid() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  final s = StringBuffer();
  for (var i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) s.write('-');
    s.write(h(i));
  }
  return s.toString();
}
