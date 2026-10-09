import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/profile_cache.dart';

void main() {
  test('a second ask within the lifetime is served from memory', () async {
    var calls = 0;
    final cache = ProfileCache(loader: (id) async {
      calls++;
      return {'id': id, 'name': 'Ann'};
    });
    expect((await cache.get('a'))!['name'], 'Ann');
    expect((await cache.get('a'))!['name'], 'Ann');
    expect(calls, 1);
  });

  test('asks that overlap share one query', () async {
    var calls = 0;
    final cache = ProfileCache(loader: (id) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return {'id': id};
    });
    final rows = await Future.wait([cache.get('a'), cache.get('a'), cache.get('a')]);
    expect(rows.every((r) => r != null), isTrue);
    expect(calls, 1);
  });

  test('an old row is read again', () async {
    var calls = 0;
    var clock = DateTime(2026, 10, 9, 12);
    final cache = ProfileCache(
      ttl: const Duration(minutes: 2),
      now: () => clock,
      loader: (id) async {
        calls++;
        return {'id': id};
      },
    );
    await cache.get('a');
    clock = clock.add(const Duration(minutes: 3));
    await cache.get('a');
    expect(calls, 2);
  });

  test('a failure or a missing row is not remembered', () async {
    var calls = 0;
    final cache = ProfileCache(loader: (id) async {
      calls++;
      if (calls == 1) throw Exception('offline');
      if (calls == 2) return null;
      return {'id': id};
    });
    expect(await cache.get('a'), isNull);
    expect(await cache.get('a'), isNull);
    expect(await cache.get('a'), isNotNull);
    expect(calls, 3);
  });

  test('a loader that throws at once does not wedge the id', () async {
    var calls = 0;
    final cache = ProfileCache(loader: (id) {
      calls++;
      if (calls == 1) throw StateError('sync failure');
      return Future.value({'id': id});
    });
    expect(await cache.get('a'), isNull);
    expect(await cache.get('a'), isNotNull);
  });

  test('put makes a row available without a query and the cache stays bounded', () async {
    var calls = 0;
    var tick = 0; // every look at the clock is one second later, so "oldest" is well defined
    final cache = ProfileCache(
      maxEntries: 2,
      now: () => DateTime(2026, 10, 9).add(Duration(seconds: tick++)),
      loader: (id) async {
        calls++;
        return {'id': id};
      },
    );
    cache.put({'id': 'x'});
    expect((await cache.get('x'))!['id'], 'x');
    expect(calls, 0);
    cache.put({'id': 'y'});
    cache.put({'id': 'z'}); // evicts the oldest
    await cache.get('x');
    expect(calls, 1);
  });
}
