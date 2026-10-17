import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/config/feature_flags.dart';
import 'package:sabalive/state/remote_config_controller.dart';

/// PK Battles are OFF unless the server says `pk_battles: true` (Application Config -> Release controls); video PK needs its own
/// `pk_video: true` on top. Decision 2026-10-17: the next Play bundle ships with PK off.
void main() {
  Future<RemoteConfigController> config(Map<String, dynamic>? row) async {
    final c = RemoteConfigController(fetch: () async => row, buildNumber: () async => 12, isIos: false);
    await c.refresh(force: true);
    return c;
  }

  test('off when the server has no opinion (a fresh install, an old row, no network)', () async {
    expect(FeatureFlags.pkBattleEnabledFor(await config(null)), isFalse);
    expect(FeatureFlags.pkBattleEnabledFor(await config({'feature_flags': <String, dynamic>{}})), isFalse);
    expect(FeatureFlags.pkBattleEnabledFor(await config({'feature_flags': {'games_enabled': true}})), isFalse);
  });

  test('the Super Admin switch turns it on, and off again', () async {
    expect(FeatureFlags.pkBattleEnabledFor(await config({'feature_flags': {'pk_battles': true}})), isTrue);
    expect(FeatureFlags.pkBattleEnabledFor(await config({'feature_flags': {'pk_battles': false}})), isFalse);
  });

  test('video PK needs both switches', () async {
    expect(FeatureFlags.pkVideoEnabledFor(await config({'feature_flags': {'pk_battles': true}})), isFalse);
    expect(FeatureFlags.pkVideoEnabledFor(await config({'feature_flags': {'pk_video': true}})), isFalse, reason: 'PK itself is off');
    expect(FeatureFlags.pkVideoEnabledFor(await config({'feature_flags': {'pk_battles': true, 'pk_video': true}})), isTrue);
    expect(FeatureFlags.pkVideoEnabledFor(await config({'feature_flags': {'pk_battles': false, 'pk_video': true}})), isFalse);
  });

  test('the app-wide answers are off before any config has been read', () {
    expect(FeatureFlags.pkBattleEnabled, isFalse);
    expect(FeatureFlags.pkVideoEnabled, isFalse);
  });
}
