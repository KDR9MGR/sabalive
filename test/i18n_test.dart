import 'package:flutter/material.dart' hide Text;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/core/i18n/text.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
  });

  test('the nine languages the app offers, in the agreed order', () {
    expect(
      [for (final l in kLanguages) l.countryName],
      [
        'India',
        'International',
        'Bangladesh · India',
        'Nepal',
        'Pakistan',
        'Egypt',
        'Nigeria',
        'Philippines',
        'Brazil',
      ],
    );
    expect({for (final l in kLanguages) l.code}.length, kLanguages.length);
    expect(languageByCode('ur').rtl, isTrue);
    expect(languageByCode('ar').rtl, isTrue);
    expect(languageByCode('hi').rtl, isFalse);
  });

  test('English and Nigerian English show the text exactly as written', () async {
    expect(tr('Cancel'), 'Cancel');
    await I18n.set(languageByCode('en_NG'));
    expect(tr('Cancel'), 'Cancel');
    expect(tr('Seat 3 is taken'), 'Seat 3 is taken');
  });

  test('every other language translates a plain string', () async {
    final expected = {
      'hi': 'रद्द करें',
      'bn': 'বাতিল করুন',
      'ne': 'रद्द गर्नुहोस्',
      'ur': 'منسوخ کریں',
      'ar': 'إلغاء',
      'fil': 'Kanselahin',
      'pt_BR': 'Cancelar',
    };
    for (final e in expected.entries) {
      await I18n.set(languageByCode(e.key));
      expect(tr('Cancel'), e.value, reason: e.key);
    }
  });

  test('a string with live values keeps the values, and the more specific template wins', () async {
    await I18n.set(languageByCode('pt_BR'));
    expect(tr('Seat 3 is taken'), 'Assento 3 está ocupado');
    expect(tr('Seat 3'), 'Assento 3');
    expect(tr('You: hello there'), 'Você: hello there');
    expect(tr('5,000 coins'), '5,000 moedas');
    expect(tr('5,000 coins added'), '5,000 moedas adicionadas');
    await I18n.set(languageByCode('hi'));
    expect(tr('Resend OTP in 00:25'), '00:25 में OTP दोबारा भेजें');
  });

  test('text with no translation (user content, new strings) passes through', () async {
    await I18n.set(languageByCode('pt_BR'));
    expect(tr('Some host wrote this title'), 'Some host wrote this title');
    expect(tr(''), '');
  });

  testWidgets('Text shows the chosen language, and switching updates what is on screen', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('Cancel'))));
    expect(find.text('Cancel'), findsOneWidget);

    await tester.runAsync(() => I18n.set(languageByCode('pt_BR')));
    await tester.pump();
    expect(find.text('Cancelar'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('Text.rich translates each piece', (tester) async {
    await I18n.set(languageByCode('pt_BR'));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Text.rich(TextSpan(children: [
            TextSpan(text: 'Already have an account? '),
            TextSpan(text: 'Login'),
          ])),
        ),
      ),
    );
    expect(find.textContaining('Já tem uma conta?', findRichText: true), findsOneWidget);
    expect(find.textContaining('Entrar', findRichText: true), findsOneWidget);
  });

  testWidgets('Arabic and Urdu lay the app out right to left; Hindi does not', (tester) async {
    Future<TextDirection> directionFor(String code) async {
      late TextDirection d;
      await tester.pumpWidget(MaterialApp(
        locale: languageByCode(code).locale,
        supportedLocales: [for (final l in kLanguages) l.locale],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Builder(builder: (context) {
          d = Directionality.of(context);
          return const SizedBox();
        }),
      ));
      await tester.pumpAndSettle();
      return d;
    }

    expect(await directionFor('ar'), TextDirection.rtl);
    expect(await directionFor('ur'), TextDirection.rtl);
    expect(await directionFor('hi'), TextDirection.ltr);
    expect(await directionFor('fil'), TextDirection.ltr);
  });
}
