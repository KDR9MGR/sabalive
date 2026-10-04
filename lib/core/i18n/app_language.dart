import 'package:flutter/widgets.dart';

/// One entry in Settings -> Language. Several countries can share a language
/// (Nigeria uses English), so each entry is a language *and* the country it is for.
class AppLanguage {
  const AppLanguage({
    required this.code,
    required this.language,
    required this.country,
    required this.nativeName,
    required this.englishName,
    required this.countryName,
  });

  /// Stable key saved on the device (and the translation table's name).
  final String code;

  /// ISO language code for the Flutter locale.
  final String language;
  final String country;

  /// How the language writes its own name.
  final String nativeName;
  final String englishName;
  final String countryName;

  Locale get locale => Locale(language, country);

  /// Right-to-left scripts flip the whole layout (Flutter does this from the locale).
  bool get rtl => language == 'ar' || language == 'ur';
}

const kLanguages = <AppLanguage>[
  AppLanguage(
    code: 'hi',
    language: 'hi',
    country: 'IN',
    nativeName: 'हिन्दी',
    englishName: 'Hindi',
    countryName: 'India',
  ),
  AppLanguage(
    code: 'en',
    language: 'en',
    country: 'US',
    nativeName: 'English',
    englishName: 'English',
    countryName: 'International',
  ),
  AppLanguage(
    code: 'bn',
    language: 'bn',
    country: 'BD',
    nativeName: 'বাংলা',
    englishName: 'Bangla',
    countryName: 'Bangladesh · India',
  ),
  AppLanguage(
    code: 'ne',
    language: 'ne',
    country: 'NP',
    nativeName: 'नेपाली',
    englishName: 'Nepali',
    countryName: 'Nepal',
  ),
  AppLanguage(
    code: 'ur',
    language: 'ur',
    country: 'PK',
    nativeName: 'اردو',
    englishName: 'Urdu',
    countryName: 'Pakistan',
  ),
  AppLanguage(
    code: 'ar',
    language: 'ar',
    country: 'EG',
    nativeName: 'العربية',
    englishName: 'Arabic',
    countryName: 'Egypt',
  ),
  AppLanguage(
    code: 'en_NG',
    language: 'en',
    country: 'NG',
    nativeName: 'English',
    englishName: 'English',
    countryName: 'Nigeria',
  ),
  AppLanguage(
    code: 'fil',
    language: 'fil',
    country: 'PH',
    nativeName: 'Filipino',
    englishName: 'Filipino',
    countryName: 'Philippines',
  ),
  AppLanguage(
    code: 'pt_BR',
    language: 'pt',
    country: 'BR',
    nativeName: 'Português',
    englishName: 'Portuguese',
    countryName: 'Brazil',
  ),
];

AppLanguage languageByCode(String? code) =>
    kLanguages.firstWhere((l) => l.code == code, orElse: () => kLanguages[1]);
