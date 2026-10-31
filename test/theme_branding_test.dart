import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabalive/core/utils/rebuild_everything.dart';
import 'package:sabalive/state/theme_config_controller.dart';
import 'package:sabalive/theme/app_colors.dart';
import 'package:sabalive/theme/app_font.dart';
import 'package:sabalive/theme/app_palette.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false; // no downloads in tests

  tearDown(() {
    AppColors.apply(AppPalette.initial);
    AppFont.use('Poppins');
  });

  group('AppPalette', () {
    test('the default brand with the Deep tone is exactly the original palette', () {
      final p = AppPalette.fromBrand(AppPalette.defaultBrand, AppPalette.defaultAccent, tone: BackgroundTone.deep);
      expect(p, AppPalette.stock);
      expect(AppPalette.stock.bg, const Color(0xFF0B0716));
      expect(AppPalette.stock.primary, const Color(0xFF9B3DF5));
    });

    test('the default tone is Rich: the original violet and pink on backgrounds that are no longer black', () {
      final p = AppPalette.fromBrand(AppPalette.defaultBrand, AppPalette.defaultAccent);
      expect(p, AppPalette.initial);
      expect(p, isNot(AppPalette.stock));
      expect(p.primary, AppPalette.stock.primary);
      expect(p.primaryDeep, AppPalette.stock.primaryDeep);
      expect(p.magenta, AppPalette.stock.magenta);
      expect(p.stockBrand, isTrue, reason: 'the original gradients stay');
      expect(p.bg.computeLuminance(), greaterThan(AppPalette.stock.bg.computeLuminance() * 3));
      AppColors.apply(p);
      expect(AppColors.brandGradient.colors.first, const Color(0xFF7C3AED));
    });

    test('an unknown or missing tone means Rich', () {
      expect(BackgroundTone.parse(null), BackgroundTone.rich);
      expect(BackgroundTone.parse('sideways'), BackgroundTone.rich);
      expect(BackgroundTone.parse(' SOFT '), BackgroundTone.soft);
      expect(BackgroundTone.parse('deep'), BackgroundTone.deep);
    });

    test('every tone of every hue has the same brightness, so a green is not murkier than a violet', () {
      double y(Color c) => c.computeLuminance();
      for (final brand in [const Color(0xFF0E9F6E), const Color(0xFF45D93A), const Color(0xFF7C3AED), const Color(0xFFE11D48), const Color(0xFFFACC15), const Color(0xFF2563EB)]) {
        final rich = AppPalette.fromBrand(brand, const Color(0xFFF5279B));
        final soft = AppPalette.fromBrand(brand, const Color(0xFFF5279B), tone: BackgroundTone.soft);
        expect(y(rich.bg), closeTo(0.026, 0.004), reason: 'rich bg of $brand');
        expect(y(rich.card), closeTo(0.049, 0.005), reason: 'rich card of $brand');
        expect(y(soft.bg), closeTo(0.06, 0.006), reason: 'soft bg of $brand');
        expect(y(soft.card), closeTo(0.092, 0.008), reason: 'soft card of $brand');
        expect(y(soft.bg), greaterThan(y(rich.bg)));
      }
    });

    test('rich and soft backgrounds are colours, not black, and the light text stays readable on every surface', () {
      // WCAG contrast of the lightest-needed text colours against the page and the surfaces stacked on it
      double contrast(Color a, Color b) {
        final la = a.computeLuminance(), lb = b.computeLuminance();
        return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
      }

      for (final tone in [BackgroundTone.rich, BackgroundTone.soft]) {
        for (final brand in [const Color(0xFF45D93A), const Color(0xFFFACC15), const Color(0xFF7C3AED), const Color(0xFF2563EB)]) {
          final p = AppPalette.fromBrand(brand, const Color(0xFFF5279B), tone: tone);
          final bg = HSLColor.fromColor(p.bg);
          expect(bg.saturation, greaterThan(0.3), reason: '$tone $brand is a colour');
          for (final c in [p.bg, p.bgElevated, p.surface, p.surfaceAlt, p.card, p.stroke]) {
            if (c == p.stroke) continue; // a border line, no text sits on it
            expect(contrast(AppColors.textPrimary, c), greaterThan(tone == BackgroundTone.rich ? 7 : 5.5), reason: '$tone $brand primary text');
            expect(contrast(AppColors.textSecondary, c), greaterThan(tone == BackgroundTone.rich ? 4.5 : 3.3), reason: '$tone $brand secondary text');
          }
          expect(contrast(AppColors.textMuted, p.bg), greaterThan(tone == BackgroundTone.rich ? 4.0 : 2.8), reason: '$tone $brand muted text on the page');
        }
      }
    });

    test('another brand colour recolours the backgrounds and the purples (Deep keeps them near black)', () {
      final p = AppPalette.fromBrand(const Color(0xFF0E9F6E), const Color(0xFFF5279B), tone: BackgroundTone.deep); // green
      expect(p, isNot(AppPalette.stock));
      final bg = HSLColor.fromColor(p.bg);
      expect(bg.lightness, lessThan(0.08));
      expect(bg.hue, closeTo(HSLColor.fromColor(const Color(0xFF0E9F6E)).hue, 2));
      // lighter surfaces stack up from the page background
      expect(HSLColor.fromColor(p.surface).lightness, greaterThan(bg.lightness));
      expect(HSLColor.fromColor(p.surfaceAlt).lightness, greaterThan(HSLColor.fromColor(p.surface).lightness));
      expect(HSLColor.fromColor(p.stroke).lightness, greaterThan(HSLColor.fromColor(p.surfaceAlt).lightness));
      expect(HSLColor.fromColor(p.primaryBright).lightness, greaterThan(HSLColor.fromColor(p.primary).lightness));
      expect(HSLColor.fromColor(p.primaryDeep).lightness, lessThan(HSLColor.fromColor(p.primary).lightness));
    });

    test('in every tone the surfaces stack up from the page background and keep the brand hue', () {
      for (final tone in BackgroundTone.values) {
        final p = AppPalette.fromBrand(const Color(0xFF45D93A), const Color(0xFFF5279B), tone: tone); // the owner's green
        double y(Color c) => c.computeLuminance();
        expect(y(p.bgElevated), greaterThan(y(p.bg)), reason: '$tone');
        expect(y(p.surface), greaterThan(y(p.bgElevated)), reason: '$tone');
        expect(y(p.surfaceAlt), greaterThan(y(p.surface)), reason: '$tone');
        expect(y(p.stroke), greaterThan(y(p.surfaceAlt)), reason: '$tone');
        expect(HSLColor.fromColor(p.bg).hue, closeTo(HSLColor.fromColor(const Color(0xFF45D93A)).hue, 3), reason: '$tone');
      }
    });

    test('a grey or white brand gives neutral backgrounds, not a colour cast', () {
      final p = AppPalette.fromBrand(const Color(0xFFFFFFFF), const Color(0xFFF5279B));
      for (final c in [p.bg, p.bgElevated, p.surface, p.stroke]) {
        final hsl = HSLColor.fromColor(c);
        expect(hsl.saturation, lessThan(0.05), reason: 'no tint');
      }
    });

    test('the accent is used as given', () {
      final p = AppPalette.fromBrand(const Color(0xFF2563EB), const Color(0xFFFFAA00));
      expect(p.magenta, const Color(0xFFFFAA00));
    });

    test('a brand too dark or too pale to read on a dark screen is lifted into range', () {
      expect(HSLColor.fromColor(AppPalette.fromBrand(const Color(0xFF000033), const Color(0xFFF5279B)).primary).lightness,
          greaterThanOrEqualTo(0.45));
      expect(HSLColor.fromColor(AppPalette.fromBrand(const Color(0xFFFFFFFF), const Color(0xFFF5279B)).primary).lightness,
          lessThanOrEqualTo(0.66));
    });

    test('AppColors follows the palette that was applied, gradients included', () {
      final p = AppPalette.fromBrand(const Color(0xFF0E9F6E), const Color(0xFFF5279B));
      AppColors.apply(p);
      expect(AppColors.bg, p.bg);
      expect(AppColors.primary, p.primary);
      expect(AppColors.brandGradient.colors.last, p.magenta);
      expect(AppColors.heroGlow.colors.last, p.bg);
      AppColors.apply(AppPalette.stock);
      expect(AppColors.bg, const Color(0xFF0B0716));
      expect(AppColors.brandGradient.colors.first, const Color(0xFF7C3AED));
    });

    test('before the branding is read the app wears the default brand with the Rich tone, not black', () {
      expect(AppColors.palette, AppPalette.initial);
      expect(AppColors.bg, isNot(const Color(0xFF0B0716)));
    });
  });

  testWidgets('a new palette reaches widgets that read AppColors while they build', (t) async {
    await t.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (_) => ColoredBox(key: const ValueKey('bg'), color: AppColors.bg)),
      ),
    );
    expect(t.widget<ColoredBox>(find.byKey(const ValueKey('bg'))).color, AppPalette.initial.bg);

    final p = AppPalette.fromBrand(const Color(0xFF0E9F6E), const Color(0xFFF5279B));
    AppColors.apply(p);
    await t.pump();
    expect(t.widget<ColoredBox>(find.byKey(const ValueKey('bg'))).color, AppPalette.initial.bg,
        reason: 'nothing rebuilds by itself');
    rebuildEverything();
    await t.pump();
    expect(t.widget<ColoredBox>(find.byKey(const ValueKey('bg'))).color, p.bg);
  });

  group('Branding', () {
    test('reads colours with or without the # and keeps the fallback for anything unreadable', () {
      final b = Branding.fromRow({'brand_color': '#0e9f6e', 'accent_color': 'nonsense', 'font_family': '  '});
      expect(b.brand, const Color(0xFF0E9F6E));
      expect(b.accent, Branding.stock.accent);
      expect(b.font, 'Poppins');
      expect(Branding.fromRow({'brand_color': '2563EB'}).brand, const Color(0xFF2563EB));
    });

    test('a row can leave a field out (it keeps what the app already had)', () {
      final had = Branding.fromRow({'brand_color': '#0e9f6e', 'font_family': 'Roboto'});
      final next = Branding.fromRow({'accent_color': '#ffaa00'}, fallback: had);
      expect(next.brand, had.brand);
      expect(next.font, 'Roboto');
      expect(next.accent, const Color(0xFFFFAA00));
    });

    test('the background tone comes from brand_tone; missing or unknown is Rich; a row without it keeps what the app had', () {
      expect(Branding.fromRow({'brand_tone': 'deep'}).tone, BackgroundTone.deep);
      expect(Branding.fromRow({'brand_tone': 'soft'}).tone, BackgroundTone.soft);
      expect(Branding.fromRow({'brand_tone': 'weird'}).tone, BackgroundTone.rich);
      expect(Branding.fromRow({'brand_tone': null}).tone, BackgroundTone.rich);
      expect(Branding.fromRow({}).tone, BackgroundTone.rich);
      final had = Branding.fromRow({'brand_tone': 'soft'});
      expect(Branding.fromRow({'brand_color': '#0e9f6e'}, fallback: had).tone, BackgroundTone.soft, reason: 'a database without the column leaves the tone alone');
    });

    test('toHex round-trips', () {
      expect(Branding.toHex(const Color(0xFF0E9F6E)), '#0e9f6e');
      expect(Branding.parseHex(Branding.toHex(const Color(0xFF123456))), const Color(0xFF123456));
    });

    test('restore applies what the last run saved, before any network', () async {
      SharedPreferences.setMockInitialValues({
        'theme.brand': '#0e9f6e',
        'theme.accent': '#ffaa00',
        'theme.font': 'Poppins',
      });
      await ThemeConfigController.restore();
      expect(AppColors.magenta, const Color(0xFFFFAA00));
      expect(AppColors.primary, isNot(AppPalette.stock.primary));
    });

    test('restore applies the saved background tone too', () async {
      SharedPreferences.setMockInitialValues({'theme.brand': '#45d93a', 'theme.accent': '#5db65f', 'theme.font': 'Poppins', 'theme.tone': 'soft'});
      await ThemeConfigController.restore();
      expect(AppColors.palette, AppPalette.fromBrand(const Color(0xFF45D93A), const Color(0xFF5DB65F), tone: BackgroundTone.soft));
    });

    test('with nothing saved the default look stays (default brand, Rich tone)', () async {
      SharedPreferences.setMockInitialValues({});
      await ThemeConfigController.restore();
      expect(AppColors.palette, AppPalette.initial);
    });
  });

  group('AppFont', () {
    test('a real Google font is accepted whatever the capitals, a made-up one is not', () {
      expect(AppFont.resolve('open sans'), 'Open Sans');
      expect(AppFont.resolve('Roboto'), 'Roboto');
      expect(AppFont.resolve('Not A Real Font 123'), isNull);
      expect(AppFont.resolve(''), isNull);
      expect(AppFont.resolve(null), isNull);
    });

    test('a made-up name keeps Poppins instead of throwing', () {
      expect(AppFont.use('Not A Real Font 123'), isFalse);
      expect(AppFont.family, 'Poppins');
      const base = TextStyle(fontSize: 14, fontWeight: FontWeight.w700);
      expect(AppFont.style(base), same(base), reason: 'the default font changes nothing');
    });

    test('a chosen font applies to text styles and keeps their weight and size', () {
      expect(AppFont.use('Roboto'), isTrue);
      expect(AppFont.isCustom, isTrue);
      final styled = AppFont.style(const TextStyle(fontSize: 14, fontWeight: FontWeight.w700));
      expect(styled.fontSize, 14);
      expect(styled.fontFamily, contains('Roboto'));
    });
  });
}
