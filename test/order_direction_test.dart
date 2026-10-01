import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// postgrest-dart's `order()` defaults to `ascending: false`, so a bare
/// `.order('level')` comes back DESCENDING — which is how the My Level list
/// ended up starting at Level 100. Every `.order(...)` must state its
/// direction so nobody relies on that default again.
void main() {
  test('every .order() states ascending: true/false', () {
    final offenders = <String>[];
    final call = RegExp(r"\.order\(\s*'[^']*'\s*(,[^)]*)?\)");
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final text = f.readAsStringSync();
      for (final m in call.allMatches(text)) {
        if (!m.group(0)!.contains('ascending')) {
          final line = text.substring(0, m.start).split('\n').length;
          offenders.add('${f.path}:$line  ${m.group(0)}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'These .order() calls rely on the library default (descending):\n'
            '${offenders.join('\n')}');
  });
}
