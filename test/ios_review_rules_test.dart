import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:sabalive/config/feature_flags.dart';
import 'package:sabalive/config/google_config.dart';
import 'package:sabalive/config/supabase_config.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/features/auth/forgot_password_screen.dart';
import 'package:sabalive/features/profile/settings_screen.dart';
import 'package:sabalive/state/auth_controller.dart';
import 'package:sabalive/theme/app_theme.dart';

/// What Apple's review (2026-10-27) means for an iPhone build: no screen that only says "coming soon", no way to buy coins outside In-App Purchase, no "alpha" wording.
/// Android must not change at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: SupabaseConfig.url, publishableKey: SupabaseConfig.publishableKey);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
  });
  tearDown(() => FeatureFlags.isIOSOverride = null);

  group('the rules', () {
    test('on iOS the placeholders, the Games entries and Buy Coins are hidden', () {
      FeatureFlags.isIOSOverride = true;
      expect(FeatureFlags.isIOS, isTrue);
      expect(FeatureFlags.comingSoonVisible, isFalse);
      expect(FeatureFlags.gamesEntryVisible, isFalse);
      expect(FeatureFlags.buyCoinsVisible, isFalse);
    });

    test('on Android nothing is hidden', () {
      FeatureFlags.isIOSOverride = false;
      expect(FeatureFlags.comingSoonVisible, isTrue);
      expect(FeatureFlags.gamesEntryVisible, isTrue);
      expect(FeatureFlags.buyCoinsVisible, isTrue);
      expect(FeatureFlags.pkToolsVisible(audioOnly: true), isTrue);
      expect(FeatureFlags.pkToolsVisible(audioOnly: false), isTrue, reason: 'Android keeps the PK tools in every live, as before');
    });

    test('on iOS the PK tools show only where PK really works (the panel switch is off here, so not at all)', () {
      FeatureFlags.isIOSOverride = true;
      expect(FeatureFlags.pkToolsVisible(audioOnly: true), FeatureFlags.pkBattleEnabled);
      expect(FeatureFlags.pkToolsVisible(audioOnly: false), FeatureFlags.pkBattleEnabled && FeatureFlags.pkVideoEnabled);
    });
  });

  group('Google sign-in', () {
    test('iOS never calls the native Google plugin (without an iOS client id it kills the whole app); Android still does', () {
      expect(GoogleConfig.isConfigured, isTrue);
      expect(GoogleConfig.nativeSignInSupported(isIOS: true), isFalse, reason: 'the browser flow is used instead');
      expect(GoogleConfig.nativeSignInSupported(isIOS: false), isTrue);
    });
  });

  group('password reset', () {
    Future<void> open(WidgetTester t) async {
      await t.pumpWidget(
        ChangeNotifierProvider(create: (_) => AuthController(), child: MaterialApp(theme: AppTheme.dark(), home: const ForgotPasswordScreen())),
      );
      await t.pump();
    }

    testWidgets('Android offers Email and Mobile, as before', (t) async {
      FeatureFlags.isIOSOverride = false;
      await open(t);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Mobile'), findsOneWidget);
    });

    testWidgets('iOS has the email way only: the Mobile tab only said "coming soon"', (t) async {
      FeatureFlags.isIOSOverride = true;
      await open(t);
      expect(find.text('Mobile'), findsNothing);
      expect(find.text('Send Reset Link'), findsOneWidget);
      expect(find.byIcon(Icons.mail_outline_rounded), findsOneWidget);
    });
  });

  group('the settings screen', () {
    Future<void> open(WidgetTester t) async {
      PackageInfo.setMockInitialValues(
        appName: 'sabalive', packageName: 'com.sabalive.in', version: '1.0.0', buildNumber: '13', buildSignature: '',
      );
      t.view.physicalSize = const Size(420, 2600); // the whole list on screen
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        ChangeNotifierProvider(create: (_) => AuthController(), child: MaterialApp(theme: AppTheme.dark(), home: const SettingsScreen())),
      );
      await t.pump();
      await t.pump();
    }

    testWidgets('shows the real app version, never "alpha"', (t) async {
      await open(t);
      expect(find.text('v1.0.0'), findsOneWidget);
      expect(find.textContaining('alpha'), findsNothing);
    });

    testWidgets('the Help text no longer talks about an alpha', (t) async {
      await open(t);
      await t.tap(find.text('Help & FAQ'));
      await t.pumpAndSettle();
      expect(find.textContaining('Need a hand? Email support@sabalive.app'), findsOneWidget);
      expect(find.textContaining('alpha'), findsNothing);
    });
  });
}
