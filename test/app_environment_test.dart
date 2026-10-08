import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/config/agora_config.dart';
import 'package:sabalive/config/app_environment.dart';
import 'package:sabalive/config/supabase_config.dart';

void main() {
  agoraDefaults();
  const staging = 'https://stagingstagingstaging.supabase.co';

  group('AppEnvironment.validate', () {
    test('a normal build is production and passes', () {
      expect(AppEnvironment.isProduction, isTrue);
      expect(AppEnvironment.isStaging, isFalse);
      expect(SupabaseConfig.url, SupabaseConfig.productionUrl);
      expect(AppEnvironment.validate, returnsNormally);
    });

    test('a staging build on the staging backend passes', () {
      expect(() => AppEnvironment.validate(environment: 'staging', url: staging), returnsNormally);
    });

    test('a staging build pointing at production is refused', () {
      expect(
        () => AppEnvironment.validate(environment: 'staging', url: SupabaseConfig.productionUrl),
        throwsStateError,
      );
    });

    test('a production build pointing anywhere else is refused', () {
      expect(() => AppEnvironment.validate(environment: 'production', url: staging), throwsStateError);
    });
  });

  group('EnvironmentRibbon', () {
    Future<void> pump(WidgetTester t, bool show) => t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          home: EnvironmentRibbon(show: show, child: const Scaffold(body: Text('app'))),
        ));

    testWidgets('a production build shows no ribbon', (t) async {
      await pump(t, false);
      expect(find.byType(Banner), findsNothing);
      expect(find.text('app'), findsOneWidget);
    });

    testWidgets('a staging build is clearly marked', (t) async {
      await pump(t, true);
      expect(find.byType(Banner), findsOneWidget);
      expect(t.widget<Banner>(find.byType(Banner)).message, 'STAGING');
      expect(find.text('app'), findsOneWidget);
    });
  });
}

void agoraDefaults() {
  group('AgoraConfig', () {
    test('a normal build uses the production App ID (a staging build overrides it with --dart-define=AGORA_APP_ID)', () {
      expect(AgoraConfig.appId, AgoraConfig.productionAppId);
    });
  });
}
