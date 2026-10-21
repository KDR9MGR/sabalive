import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/core/i18n/text.dart';
import 'package:sabalive/data/countries.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/auth/profile_completion_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The "Complete your profile" step after login: who is asked, the 13+ rule, the country list, and what the screen does.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppUser person({DateTime? dob, String location = 'India', bool ghost = false}) =>
      AppUser(id: 'u', name: 'Xyz', username: '@xyz', dateOfBirth: dob, location: location, isGhost: ghost);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
  });

  group('who is asked', () {
    test('nobody signed in or loaded yet: nothing to ask', () {
      expect(needsProfileCompletion(null), isFalse);
    });

    test('no date of birth: asked, whatever the country says (every account starts as India)', () {
      expect(needsProfileCompletion(person()), isTrue);
      expect(needsProfileCompletion(person(location: 'Nepal')), isTrue);
    });

    test('a saved date of birth and a country: done', () {
      expect(needsProfileCompletion(person(dob: DateTime(2000, 5, 1))), isFalse);
    });

    test('a saved date of birth but an empty country: asked again', () {
      expect(needsProfileCompletion(person(dob: DateTime(2000, 5, 1), location: '  ')), isTrue);
    });

    test('a ghost account is never asked', () {
      expect(needsProfileCompletion(person(ghost: true)), isFalse);
    });
  });

  group('13 and over', () {
    final today = DateTime(2026, 10, 21);

    test('somebody turning 13 today is old enough, one day younger is not', () {
      expect(oldEnough(DateTime(2013, 10, 21), today), isTrue);
      expect(oldEnough(DateTime(2013, 10, 22), today), isFalse);
      expect(oldEnough(DateTime(1990, 1, 1), today), isTrue);
    });

    test('the latest allowed birth date moves with today', () {
      expect(latestBirthDate(today), DateTime(2013, 10, 21));
    });

    test('the message names the same age as the rule', () {
      expect(kUnderAgeMessage, contains('$kMinimumAge'));
    });
  });

  group('the country list', () {
    test('has India and no repeats, and every name is plain text', () {
      expect(kCountries, contains('India'));
      expect(kCountries.toSet().length, kCountries.length);
      expect(kCountries.every((c) => c.trim() == c && c.isNotEmpty), isTrue);
    });

    test('search finds part of a name in any case and keeps the list order', () {
      expect(searchCountries('ind'), ['India', 'Indonesia']);
      expect(searchCountries('  NEPAL '), ['Nepal']);
      expect(searchCountries('zzzz'), isEmpty);
      expect(searchCountries(''), kCountries);
    });
  });

  group('the screen', () {
    Future<void> open(WidgetTester t, {required Future<void> Function(DateTime, String) onSave, Future<void> Function()? onSignOut}) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: ProfileCompletionScreen(onSave: onSave, onSignOut: onSignOut ?? () async {}, now: DateTime(2026, 10, 21)),
      ));
    }

    Future<void> pickDob(WidgetTester t) async {
      await t.tap(find.byKey(const ValueKey('complete-dob')));
      await t.pumpAndSettle();
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
    }

    Future<void> pickCountry(WidgetTester t, String search, String name) async {
      await t.tap(find.byKey(const ValueKey('complete-country')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('country-search')), search);
      await t.pumpAndSettle();
      await t.tap(find.byKey(ValueKey('country-$name')));
      await t.pumpAndSettle();
    }

    testWidgets('it asks for both and cannot be continued until both are given', (t) async {
      var saved = 0;
      await open(t, onSave: (d, c) async => saved++);
      expect(find.text('Complete your profile'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('complete-continue')));
      await t.pump();
      expect(saved, 0, reason: 'nothing chosen');
      await pickDob(t);
      await t.tap(find.byKey(const ValueKey('complete-continue')));
      await t.pump();
      expect(saved, 0, reason: 'no country yet');
    });

    testWidgets('both chosen: Continue saves the date and the English country name', (t) async {
      DateTime? dob;
      String? country;
      await open(t, onSave: (d, c) async {
        dob = d;
        country = c;
      });
      await pickDob(t);
      await pickCountry(t, 'ind', 'India');
      expect(find.text('India'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('complete-continue')));
      await t.pump();
      expect(country, 'India');
      expect(dob, DateTime(2008, 10, 21), reason: 'the picker opens 18 years back and OK keeps it');
    });

    testWidgets('the country search narrows the list and says so when nothing matches', (t) async {
      await open(t, onSave: (d, c) async {});
      await t.tap(find.byKey(const ValueKey('complete-country')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('country-search')), 'ind');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('country-India')), findsOneWidget);
      expect(find.byKey(const ValueKey('country-Indonesia')), findsOneWidget);
      expect(find.byKey(const ValueKey('country-Nepal')), findsNothing);
      await t.enterText(find.byKey(const ValueKey('country-search')), 'qqqq');
      await t.pumpAndSettle();
      expect(find.text('No country found'), findsOneWidget);
    });

    testWidgets('a failed save shows an error and lets the person try again', (t) async {
      var tries = 0;
      await open(t, onSave: (d, c) async {
        tries++;
        throw Exception('network down');
      });
      await pickDob(t);
      await pickCountry(t, 'nep', 'Nepal');
      await t.tap(find.byKey(const ValueKey('complete-continue')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('complete-error')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('complete-continue')));
      await t.pumpAndSettle();
      expect(tries, 2);
    });

    testWidgets('Sign Out is the only other way out', (t) async {
      var out = 0;
      await open(t, onSave: (d, c) async {}, onSignOut: () async => out++);
      await t.tap(find.byKey(const ValueKey('complete-signout')));
      await t.pump();
      expect(out, 1);
    });
  });

  group('translations', () {
    test('every new line of this step and of the Fans list is translated in all seven languages', () async {
      const lines = [
        'Complete your profile',
        'We need your date of birth and country before you continue.',
        'Select your country',
        'Search country',
        kUnderAgeMessage,
        'No country found',
        'No fans yet. Fans are people you follow who follow you back.',
      ];
      for (final l in kLanguages.where((l) => !const {'en', 'en_NG'}.contains(l.code))) {
        await I18n.set(l);
        for (final text in lines) {
          expect(tr(text), isNot(text), reason: '${l.code} has no translation of: $text');
        }
        expect(tr(kUnderAgeMessage), contains('SABALIVE'), reason: l.code);
      }
    });
  });

  group('the gate', () {
    Widget gate(AppUser? user, {Duration wait = const Duration(milliseconds: 50)}) => MaterialApp(
          home: ProfileCompletionGateView(
            user: user,
            wait: wait,
            onSave: (d, c) async {},
            onSignOut: () async {},
            child: const Scaffold(body: Text('HOME', textDirection: TextDirection.ltr)),
          ),
        );

    testWidgets('a person without a date of birth gets the screen, not the app', (t) async {
      await t.pumpWidget(gate(person()));
      expect(find.byKey(const ValueKey('complete-title')), findsOneWidget);
      expect(find.text('HOME'), findsNothing);
    });

    testWidgets('a person who has them goes straight in', (t) async {
      await t.pumpWidget(gate(person(dob: DateTime(1999, 3, 4))));
      expect(find.text('HOME'), findsOneWidget);
      expect(find.byKey(const ValueKey('complete-title')), findsNothing);
    });

    testWidgets('a ghost goes straight in', (t) async {
      await t.pumpWidget(gate(person(ghost: true)));
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('the moment the profile is completed the app opens', (t) async {
      await t.pumpWidget(gate(person()));
      expect(find.text('HOME'), findsNothing);
      await t.pumpWidget(gate(person(dob: DateTime(1999, 3, 4))));
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('while the profile is still loading it waits, then opens the app if it never arrives (offline)', (t) async {
      await t.pumpWidget(gate(null));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('HOME'), findsNothing);
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('a profile that arrives during the wait is judged normally', (t) async {
      await t.pumpWidget(gate(null, wait: const Duration(seconds: 4)));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await t.pumpWidget(gate(person(), wait: const Duration(seconds: 4)));
      expect(find.byKey(const ValueKey('complete-title')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });
}
