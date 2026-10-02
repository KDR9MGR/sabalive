import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabalive/services/device_identity_service.dart';

DeviceIdentityService _service(
  Future<RawDeviceInfo> Function() reader, {
  int seed = 1,
}) => DeviceIdentityService(
  reader: reader,
  prefs: SharedPreferences.getInstance,
  random: Random(seed),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('uses the platform id, tagged with where it came from', () async {
    final id = await _service(
      () async => const RawDeviceInfo(platform: 'android', rawId: '9774d56d682e549c', model: 'Pixel 8'),
    ).load();
    expect(id.id, 'android:9774d56d682e549c');
    expect(id.platform, 'android');
    expect(id.model, 'Pixel 8');
  });

  test('an iOS vendor id works the same way', () async {
    final id = await _service(
      () async => const RawDeviceInfo(platform: 'ios', rawId: 'ABCD-1234', model: 'iPhone15,2'),
    ).load();
    expect(id.id, 'ios:ABCD-1234');
  });

  test('a missing platform id falls back to a random one that is remembered', () async {
    final first = await _service(() async => const RawDeviceInfo(platform: 'android')).load();
    expect(first.id, startsWith('install:'));
    expect(first.id.length, greaterThan('install:'.length + 16));
    // a brand-new service instance (a fresh app start) finds the same id
    final second = await _service(() async => const RawDeviceInfo(platform: 'android'), seed: 99).load();
    expect(second.id, first.id);
  });

  test('a blank id counts as missing', () async {
    final id = await _service(() async => const RawDeviceInfo(platform: 'ios', rawId: '   ')).load();
    expect(id.id, startsWith('install:'));
  });

  test('a plugin failure falls back instead of crashing app start', () async {
    final id = await _service(() async => throw Exception('no plugin')).load();
    expect(id.id, startsWith('install:'));
    expect(id.platform, 'unknown');
  });

  test('is read once and then cached', () async {
    var reads = 0;
    final service = _service(() async {
      reads++;
      return const RawDeviceInfo(platform: 'android', rawId: 'abc');
    });
    await service.load();
    await service.load();
    expect(reads, 1);
    expect(service.current?.id, 'android:abc');
  });

  test('the id is plain ASCII, safe in an HTTP header', () async {
    final id = await _service(() async => const RawDeviceInfo(platform: 'android')).load();
    expect(RegExp(r'^[A-Za-z0-9:_\-]+$').hasMatch(id.id), isTrue);
  });
}
