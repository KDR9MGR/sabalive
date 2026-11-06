import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/data/countries.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/profile/widgets/country_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A flag for every country in the picker, and the flag of the chosen country on a profile (2026-11-05).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
  });

  group('the codes', () {
    test('every country in the picker has a two-letter code, and nothing else is in the table', () {
      for (final c in kCountries) {
        expect(kCountryCodes[c], isNotNull, reason: c);
        expect(RegExp(r'^[A-Z]{2}$').hasMatch(kCountryCodes[c]!), isTrue, reason: '$c -> ${kCountryCodes[c]}');
      }
      expect(kCountryCodes.length, kCountries.length);
      expect(kCountryCodes.keys.toSet(), kCountries.toSet());
    });

    test('no two countries share a code, so no two share a flag', () {
      expect(kCountryCodes.values.toSet().length, kCountryCodes.length);
    });

    test('every flag is exactly two regional-indicator symbols', () {
      for (final c in kCountries) {
        final flag = flagOfCountry(c)!;
        final runes = flag.runes.toList();
        expect(runes.length, 2, reason: c);
        for (final r in runes) {
          expect(r, inInclusiveRange(0x1F1E6, 0x1F1FF), reason: c);
        }
      }
    });
  });

  group('looking a flag up', () {
    test('some well-known ones', () {
      expect(flagOfCountry('India'), '🇮🇳');
      expect(flagOfCountry('United States'), '🇺🇸');
      expect(flagOfCountry('United Kingdom'), '🇬🇧');
      expect(flagOfCountry('Bangladesh'), '🇧🇩');
      expect(flagOfCountry('Pakistan'), '🇵🇰');
      expect(flagOfCountry('Nigeria'), '🇳🇬');
      expect(flagOfCountry('Philippines'), '🇵🇭');
      expect(flagOfCountry('Brazil'), '🇧🇷');
      expect(flagOfCountry('Egypt'), '🇪🇬');
      expect(flagOfCountry("Côte d'Ivoire"), '🇨🇮');
    });

    test('capitals and spaces around the name do not matter', () {
      expect(flagOfCountry('  india '), '🇮🇳');
      expect(flagOfCountry('NEPAL'), '🇳🇵');
    });

    test('text that is not a listed country has no flag: nothing is guessed', () {
      expect(flagOfCountry('Mumbai'), isNull);
      expect(flagOfCountry(''), isNull);
      expect(flagOfCountry('   '), isNull);
      expect(flagOfCountry(null), isNull);
      expect(flagOfCountry('Indiaa'), isNull);
    });

    test('flagOfCode takes two letters only', () {
      expect(flagOfCode('in'), '🇮🇳');
      expect(flagOfCode('IN '), '🇮🇳');
      expect(flagOfCode('I'), isNull);
      expect(flagOfCode('IND'), isNull);
      expect(flagOfCode('1N'), isNull);
      expect(flagOfCode(null), isNull);
    });
  });

  group('on a profile', () {
    AppUser person({DateTime? dob, String location = 'India'}) => AppUser(id: 'u', name: 'N', username: '@n', location: location)..dateOfBirth = dob;

    test('somebody who completed the step wears the flag of the country they chose', () {
      expect(flagOfUser(person(dob: DateTime(2000, 1, 1), location: 'Nepal')), '🇳🇵');
      expect(flagOfUser(person(dob: DateTime(2000, 1, 1), location: 'India')), '🇮🇳');
    });

    test('somebody who never completed it wears none: "India" is only the database default, not a choice', () {
      expect(flagOfUser(person(dob: null, location: 'India')), isNull);
    });

    test('an old free-text location (a city) has no flag', () {
      expect(flagOfUser(person(dob: DateTime(2000, 1, 1), location: 'Mumbai')), isNull);
    });
  });

  group('the widgets', () {
    testWidgets('a flag draws, no flag draws nothing', (t) async {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: Column(children: [CountryFlag('🇮🇳'), CountryFlag(null, key: ValueKey('none'))]))));
      expect(find.byKey(const ValueKey('country-flag')), findsOneWidget);
      expect(find.text('🇮🇳'), findsOneWidget);
      expect(t.getSize(find.byKey(const ValueKey('none'))), Size.zero);
    });

    testWidgets('the list shows each country with its flag; search narrows it; a tap returns the English name', (t) async {
      String? picked;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => picked = await showCountrySheet(context, selected: 'India'),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('country-Afghanistan')), findsOneWidget);
      expect(find.text('🇦🇫'), findsOneWidget, reason: 'the first country has its flag');
      await t.enterText(find.byKey(const ValueKey('country-search')), 'nepal');
      await t.pumpAndSettle();
      expect(find.text('🇳🇵'), findsOneWidget);
      expect(find.text('🇦🇫'), findsNothing);
      await t.tap(find.byKey(const ValueKey('country-Nepal')));
      await t.pumpAndSettle();
      expect(picked, 'Nepal');
    });
  });
}
