import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:sabalive/config/supabase_config.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/core/utils/email.dart';
import 'package:sabalive/features/auth/forgot_password_screen.dart';
import 'package:sabalive/features/auth/login_screen.dart';
import 'package:sabalive/state/auth_controller.dart';
import 'package:sabalive/theme/app_theme.dart';

/// The login screen is email only (owner, 2026-11-06): no phone number, no Username tab, no "Login with OTP"; Forgot Password has no Mobile way either.
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

  Future<void> open(WidgetTester t, Widget home) async {
    t.view.physicalSize = const Size(640, 1100); // wide: the test font draws every letter as a block, so the real phone width would overflow the Sign Up row
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(ChangeNotifierProvider(create: (_) => AuthController(), child: MaterialApp(theme: AppTheme.dark(), home: home)));
    await t.pump();
  }

  group('what the login screen offers', () {
    testWidgets('an email box and a password box, the Login button, Forgot Password and Sign Up', (t) async {
      await open(t, const LoginScreen());
      expect(find.byKey(const ValueKey('login-email')), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Email'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
      expect(find.text('Login'), findsOneWidget);
      expect(find.text('Forgot Password?'), findsOneWidget);
      expect(find.text('Sign Up'), findsOneWidget);
    });

    testWidgets('no phone anywhere: no "Phone" word, no phone number hint, no Username tab, no tab row at all', (t) async {
      await open(t, const LoginScreen());
      expect(find.textContaining('hone'), findsNothing);
      expect(find.textContaining('Email / '), findsNothing);
      expect(find.text('Username'), findsNothing);
      expect(find.byIcon(Icons.person_outline_rounded), findsNothing);
      expect(find.byIcon(Icons.phone_outlined), findsNothing);
    });

    testWidgets('no "Login with OTP" button and nothing that sends a text message', (t) async {
      await open(t, const LoginScreen());
      expect(find.text('Login with OTP'), findsNothing);
      expect(find.textContaining('OTP'), findsNothing);
      expect(find.byIcon(Icons.sms_outlined), findsNothing);
    });

    testWidgets('the email box brings up the email keyboard', (t) async {
      await open(t, const LoginScreen());
      expect(t.widget<TextField>(find.byKey(const ValueKey('login-email'))).keyboardType, TextInputType.emailAddress);
    });
  });

  group('typing something that is not an email', () {
    for (final typed in ['', '   ', '9876543210', '+91 98765 43210', 'some_username', 'no-at-sign.com', 'a@b']) {
      testWidgets('"$typed" is refused with a sentence, before anything is sent anywhere', (t) async {
        await open(t, const LoginScreen());
        await t.enterText(find.byKey(const ValueKey('login-email')), typed);
        await t.enterText(find.widgetWithText(TextField, 'Password'), 'whatever1');
        await t.tap(find.text('Login'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 100));
        expect(find.text('Enter your email address'), findsOneWidget);
      });
    }
  });

  group('the email check', () {
    test('a normal address passes, with or without spaces around it', () {
      for (final ok in ['nisha.sharma@email.com', 'a@b.co', '  me+tag@mail.example.org  ', 'x_y@sub.domain.in']) {
        expect(isEmailAddress(ok), isTrue, reason: ok);
      }
    });

    test('phone numbers, usernames and half addresses do not', () {
      for (final bad in ['', ' ', '9876543210', '+919876543210', 'username', '@email.com', 'me@', 'me@email', 'me @email.com', 'me@@email.com', 'me@email .com']) {
        expect(isEmailAddress(bad), isFalse, reason: '"$bad"');
      }
    });
  });

  group('Forgot Password', () {
    testWidgets('email only: no Mobile tab, no phone box, no "mobile number" wording', (t) async {
      await open(t, const ForgotPasswordScreen());
      expect(find.text('Mobile'), findsNothing);
      expect(find.textContaining('mobile'), findsNothing);
      expect(find.byIcon(Icons.phone_outlined), findsNothing);
      expect(find.byIcon(Icons.mail_outline_rounded), findsOneWidget);
      expect(find.text('Send Reset Link'), findsOneWidget);
    });
  });
}
