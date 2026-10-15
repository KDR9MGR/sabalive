import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/config/feature_flags.dart';
import 'package:sabalive/state/remote_config_controller.dart';

/// PK Battles are on unless the server says `pk_battles: false` (Application Config -> Release controls).
void main() {
  Future<RemoteConfigController> config(Map<String, dynamic>? row) async {
    final c = RemoteConfigController(fetch: () async => row, buildNumber: () async => 10, isIos: false);
    await c.refresh(force: true);
    return c;
  }

  test('on when the server has no opinion (a fresh install, an old row, no network)', () async {
    expect(FeatureFlags.pkBattleEnabledFor(await config(null)), isTrue);
    expect(FeatureFlags.pkBattleEnabledFor(await config({'feature_flags': <String, dynamic>{}})), isTrue);
    expect(FeatureFlags.pkBattleEnabledFor(await config({'feature_flags': {'games_enabled': true}})), isTrue);
  });

  test('the Super Admin switch turns it off, and on again', () async {
    expect(FeatureFlags.pkBattleEnabledFor(await config({'feature_flags': {'pk_battles': false}})), isFalse);
    expect(FeatureFlags.pkBattleEnabledFor(await config({'feature_flags': {'pk_battles': true}})), isTrue);
  });

  test('the app-wide answer is on before any config has been read', () {
    expect(FeatureFlags.pkBattleEnabled, isTrue);
  });
}
